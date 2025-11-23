-- fibers/op.lua

--- Concurrent ML style operations for structured concurrency.
--- Provides composable operations (ops) that may complete immediately
--- or block, with support for choice, guards, negative acknowledgements
--- and abort/cleanup behaviour.
---@module 'fibers.op'

local runtime = require 'fibers.runtime'
local safe    = require 'coxpcall'
local oneshot = require 'fibers.oneshot'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

local function id_wrap(...) return ... end

----------------------------------------------------------------------
-- Suspensions and completion tasks
----------------------------------------------------------------------

--- A suspension of a fiber waiting on an op.
---@class Suspension
---@field state "waiting"|"synchronized"   # whether the suspension is still pending
---@field sched Scheduler                  # scheduler used to reschedule the fiber
---@field fiber Fiber                      # fiber object to resume
---@field wrap WrapFn|nil                  # wrap function to apply on resume
---@field val table|nil                    # packed resume values
local Suspension = {}
Suspension.__index = Suspension

---@class CompleteTask : Task
---@field suspension Suspension               # suspension to complete
---@field wrap WrapFn                         # wrap function applied on completion
---@field val table                           # packed completion values
local CompleteTask = {}
CompleteTask.__index = CompleteTask

--- Check whether the suspension is still waiting.
---@return boolean
function Suspension:waiting()
    return self.state == 'waiting'
end

--- Mark a suspension as complete and enqueue it on the scheduler.
---@param wrap WrapFn
---@param ... any
function Suspension:complete(wrap, ...)
    assert(self:waiting())
    self.state = 'synchronized'
    self.wrap  = wrap
    self.val   = pack(...)
    self.sched:schedule(self)
end

--- Complete a suspension and resume the fiber immediately.
---@param wrap WrapFn
---@param ... any
---@return any
function Suspension:complete_and_run(wrap, ...)
    assert(self:waiting())
    self.state = 'synchronized'
    return self.fiber:resume(wrap, ...)
end

--- Create a task that will complete this suspension when run.
---@param wrap WrapFn
---@param ... any
---@return CompleteTask
function Suspension:complete_task(wrap, ...)
    return setmetatable({ suspension = self, wrap = wrap, val = pack(...) }, CompleteTask)
end

--- Run the suspension completion task as a scheduled task.
function Suspension:run()
    assert(not self:waiting())
    return self.fiber:resume(self.wrap, unpack(self.val, 1, self.val.n))
end

---@param sched Scheduler
---@param fib any
---@return Suspension
local function new_suspension(sched, fib)
    return setmetatable({ state = 'waiting', sched = sched, fiber = fib }, Suspension)
end

--- A CompleteTask completes a suspension (if still waiting) when run.
function CompleteTask:run()
    if self.suspension:waiting() then
        self.suspension:complete_and_run(self.wrap, unpack(self.val, 1, self.val.n))
    end
end

--- Cancel a CompleteTask, completing the suspension with a tagged result.
---@param reason? string
function CompleteTask:cancel(reason)
    if self.suspension:waiting() then
        local msg = reason or 'cancelled'
        local function cancelled_wrap()
            -- Convention: (ok:boolean, value_or_reason:any)
            return false, msg
        end
        self.suspension:complete(cancelled_wrap)
    end
end

----------------------------------------------------------------------
-- Op type (unifies primitive and composite ops)
----------------------------------------------------------------------

---@alias WrapFn fun(...: any): ...
---@alias TryFn fun(): boolean, ...
---@alias BlockFn fun(suspension: Suspension, wrap_fn: WrapFn)

--- Negative acknowledgement condition used by with_nack/abort.
---@class NackCond
---@field wait_op fun(): Op   # op that becomes ready when the condition fires (if present)
---@field signal fun()        # trigger the condition (idempotent)

--- Compiled primitive leaf of an op tree.
---@class CompiledLeaf
---@field try_fn TryFn
---@field block_fn BlockFn
---@field wrap WrapFn
---@field nacks NackCond[]

--- General op representation (primitive or composite).
---@class Op
---@field kind "prim"|"choice"|"guard"|"with_nack"|"wrap"|"abort"
---@field ops Op[]|nil
---@field builder fun(...: any): Op
---@field wrap_fn WrapFn|nil
---@field inner Op|nil
---@field abort_fn fun()|nil
---@field try_fn TryFn|nil
---@field block_fn BlockFn|nil
local Op = {}
Op.__index = Op

-- Forward declaration so compile_op can refer to perform.
local perform

--- Construct a primitive op.
---   try_fn() -> success:boolean, ...
---   block_fn(suspension, wrap_fn) must arrange asynchronous completion
---   by calling suspension:complete(...), typically from an event handler;
---   it must not resume the fiber synchronously via complete_and_run().
---@param wrap_fn? WrapFn
---@param try_fn TryFn
---@param block_fn BlockFn
---@return Op
local function new_primitive(wrap_fn, try_fn, block_fn)
    return setmetatable(
        {
            kind     = 'prim',
            wrap_fn  = wrap_fn or id_wrap,
            try_fn   = try_fn,
            block_fn = block_fn,
        },
        Op
    )
end

--- Choice op over a non-empty list of sub-ops.
--- Nested choices are flattened.
---@param ... Op
---@return Op
local function choice(...)
    local ops = {}
    for _, op in ipairs({ ... }) do
        if op.kind == 'choice' then
            for _, sub in ipairs(op.ops) do
                ops[#ops + 1] = sub
            end
        else
            ops[#ops + 1] = op
        end
    end
    if #ops == 1 then return ops[1] end
    return setmetatable({ kind = 'choice', ops = ops }, Op)
end

--- Delayed op builder; executed once per synchronisation.
---@param g fun(): Op
---@return Op
local function guard(g)
    return setmetatable({ kind = 'guard', builder = g }, Op)
end

--- CML-style with_nack.
--- The builder is passed a nack op that becomes ready if this arm loses in a choice.
---@param g fun(nack_op: Op): Op
---@return Op
local function with_nack(g)
    return setmetatable({ kind = 'with_nack', builder = g }, Op)
end

--- Op that is immediately ready with the given results.
---@param ... any
---@return Op
local function always(...)
    local results = pack(...)
    local function try()
        return true, unpack(results, 1, results.n)
    end
    local function block() error("always: block_fn should never run") end
    return new_primitive(nil, try, block)
end

--- Op that never becomes ready.
---@return Op
local function never()
    return new_primitive(
        nil,
        function() return false end,
        function() end
    )
end

--- Wrap this op with a post-processing function f (commit phase).
--- Wraps compose in declaration order.
---@param f WrapFn
---@return Op
function Op:wrap(f)
    return setmetatable(
        { kind = 'wrap', inner = self, wrap_fn = f },
        Op
    )
end

--- Attach an abort handler to this op.
--- f() is run if this op participates in a choice and does not win.
---@param f fun()
---@return Op
function Op:on_abort(f)
    assert(type(f) == 'function', "on_abort expects a function")
    return setmetatable(
        { kind = 'abort', inner = self, abort_fn = f },
        Op
    )
end

----------------------------------------------------------------------
-- Simple one-shot condition primitive (used for with_nack)
----------------------------------------------------------------------

--- Create a nack condition optionally carrying an abort handler.
---@param opts? { abort_fn: fun() }
---@return NackCond
local function new_cond(opts)
    local abort_fn = opts and opts.abort_fn or nil

    -- Oneshot runs abort_fn (if any) after all waiters have been invoked.
    local os = oneshot.new(function()
        if abort_fn then
            safe.pcall(abort_fn)
        end
    end)

    local function wait_op()
        assert(not abort_fn, "abort-only cond has no wait_op")

        local function try()
            return os:is_triggered()
        end

        local function block(suspension, wrap_fn)
            -- If already triggered, add_waiter will run the thunk immediately.
            os:add_waiter(function()
                if suspension:waiting() then
                    suspension:complete(wrap_fn)
                end
            end)
        end

        return new_primitive(nil, try, block)
    end

    local function signal()
        os:signal()
    end

    return {
        wait_op = wait_op,
        signal  = signal,
    }
end

----------------------------------------------------------------------
-- Compile an op tree into primitive leaves
----------------------------------------------------------------------

---@param op Op
---@param outer_wrap? WrapFn
---@param out? CompiledLeaf[]
---@param nacks? NackCond[]
---@return CompiledLeaf[]
local function compile_op(op, outer_wrap, out, nacks)
    out        = out or {}
    outer_wrap = outer_wrap or id_wrap
    nacks      = nacks or {}

    local kind = op.kind

    if kind == 'choice' then
        for _, sub in ipairs(op.ops) do
            compile_op(sub, outer_wrap, out, nacks)
        end

    elseif kind == 'guard' then
        local inner = op.builder()
        compile_op(inner, outer_wrap, out, nacks)

    elseif kind == 'with_nack' then
        local cond    = new_cond()
        local nack_op = cond.wait_op()
        local inner   = op.builder(nack_op)

        local child_nacks = { unpack(nacks) }
        child_nacks[#child_nacks + 1] = cond
        compile_op(inner, outer_wrap, out, child_nacks)

    elseif kind == 'wrap' then
        -- Wraps compose in declaration order: op:wrap(f1):wrap(f2) → f2(f1(...)).
        local f         = assert(op.wrap_fn)
        local new_outer = function(...)
            return outer_wrap(f(...))
        end
        compile_op(op.inner, new_outer, out, nacks)

    elseif kind == 'abort' then
        local cond        = new_cond{ abort_fn = op.abort_fn }
        local child_nacks = { unpack(nacks) }
        child_nacks[#child_nacks + 1] = cond
        compile_op(op.inner, outer_wrap, out, child_nacks)

    else -- 'prim'
        local function wrapped(...)
            -- Any Lua error here is treated as a bug and propagates normally.
            return outer_wrap(op.wrap_fn(...))
        end

        out[#out + 1] = {
            try_fn   = op.try_fn,
            block_fn = op.block_fn,
            wrap     = wrapped,
            nacks    = nacks,
        }
    end

    return out
end

----------------------------------------------------------------------
-- Nack triggering and non-blocking attempt
----------------------------------------------------------------------

--- Signal all nack conditions belonging exclusively to losing arms.
---@param ops CompiledLeaf[]
---@param winner_index? integer
local function trigger_nacks(ops, winner_index)
    local winner_set
    if winner_index then
        winner_set = {}
        local wnacks = ops[winner_index].nacks
        if wnacks then
            for i = 1, #wnacks do
                winner_set[wnacks[i]] = true
            end
        end
    end

    local function is_winner_cond(cond)
        return winner_set and winner_set[cond] or false
    end

    local signalled = {}
    for i = 1, #ops do
        if not winner_index or i ~= winner_index then
            local nacks = ops[i].nacks
            if nacks then
                for j = #nacks, 1, -1 do
                    local cond = nacks[j]
                    if cond and not is_winner_cond(cond) and not signalled[cond] then
                        signalled[cond] = true
                        cond.signal()
                    end
                end
            end
        end
    end
end

--- Try once to find a ready leaf in ops (random probe order).
--- Returns winner_index and packed results, or nil if none are ready.
---@param ops CompiledLeaf[]
---@return integer|nil, table|nil
local function try_ready(ops)
    local n = #ops
    if n == 0 then return nil end
    local base = math.random(n)
    for i = 1, n do
        local idx    = ((i + base) % n) + 1
        local op     = ops[idx]
        local retval = pack(op.try_fn())
        if retval[1] then
            return idx, retval
        end
    end
    return nil
end

--- Apply a leaf's wrap to its packed results.
---@param wrap WrapFn
---@param retval table|nil
---@return any ...
local function apply_wrap(wrap, retval)
    assert(retval ~= nil, "apply_wrap: retval must not be nil")
    ---@cast retval table
    return wrap(unpack(retval, 2, retval.n))
end

----------------------------------------------------------------------
-- or_else: biased, non-blocking choice
----------------------------------------------------------------------

--- Non-blocking choice: try this op, otherwise run fallback_thunk.
---@param fallback_thunk fun(): any
---@return Op
function Op:or_else(fallback_thunk)
    assert(type(fallback_thunk) == "function", "or_else expects a function")

    return guard(function()
        local leaves = compile_op(self)

        local idx, retval = try_ready(leaves)
        if idx then
            trigger_nacks(leaves, idx)
            local results = pack(apply_wrap(leaves[idx].wrap, retval))
            return always(unpack(results, 1, results.n))
        end

        trigger_nacks(leaves, nil)

        local results = pack(fallback_thunk())
        return always(unpack(results, 1, results.n))
    end)
end

----------------------------------------------------------------------
-- Blocking choice path
----------------------------------------------------------------------

--- Block the current fiber until one of the compiled leaves completes.
---@param sched Scheduler
---@param fib any
---@param ops CompiledLeaf[]
local function block_choice_op(sched, fib, ops)
    local suspension = new_suspension(sched, fib)
    for _, op in ipairs(ops) do
        op.block_fn(suspension, op.wrap)
    end
end

----------------------------------------------------------------------
-- Op methods: perform
----------------------------------------------------------------------

--- Perform this op (primitive or composite), blocking if necessary.
--- Must be called from within a fiber; errors propagate as normal Lua errors.
---@param op Op
---@return any ...
perform = function(op)
    assert(runtime.current_fiber(), "perform_raw must be called from inside a fiber (use fibers.run as an entry point)")
    local leaves = compile_op(op)

    -- Fast path: non-blocking attempt.
    local idx, retval = try_ready(leaves)
    if idx then
        trigger_nacks(leaves, idx)
        return apply_wrap(leaves[idx].wrap, retval)
    end

    -- Slow path: block all leaves.
    local suspended = pack(runtime.suspend(block_choice_op, leaves))
    local wrap      = suspended[1]

    local winner_index
    for i, leaf in ipairs(leaves) do
        if leaf.wrap == wrap then
            winner_index = i
            break
        end
    end

    trigger_nacks(leaves, winner_index)
    return wrap(unpack(suspended, 2, suspended.n))
end

----------------------------------------------------------------------
-- bracket : (acquire, release, use) -> 'a op
----------------------------------------------------------------------

--- Resource-safe wrapper for an op.
--- acquire() obtains a resource, release(resource, aborted) cleans it up,
--- and use(resource) returns the op that uses it.
---@param acquire fun(): any
---@param release fun(resource: any, aborted: boolean)
---@param use fun(resource: any): Op
---@return Op
local function bracket(acquire, release, use)
    assert(type(acquire) == "function", "bracket: acquire must be a function")
    assert(type(release) == "function", "bracket: release must be a function")
    assert(type(use) == "function", "bracket: use must be a function")

    return guard(function()
        local res = acquire()
        local op  = use(res)

        local wrapped = op:wrap(function(...)
            release(res, false)
            return ...
        end)

        return wrapped:on_abort(function()
            release(res, true)
        end)
    end)
end

----------------------------------------------------------------------
-- finally : (op, cleanup) -> op'
----------------------------------------------------------------------

--- Attach cleanup(aborted) to an op.
--- cleanup is called with aborted=true if the op loses in a choice.
---@param cleanup fun(aborted: boolean)
---@return Op
function Op:finally(cleanup)
    assert(type(cleanup) == "function", "finally expects a function")

    return bracket(
        function() return nil end,
        function(_, aborted) cleanup(aborted) end,
        function() return self end
    )
end

----------------------------------------------------------------------
-- Higher-level choice helpers
----------------------------------------------------------------------

--- Race a list of ops, applying on_win(index, ...) to the winner's result.
---@param ops Op[]
---@param on_win fun(index: integer, ...: any): ...
---@return Op
local function race(ops, on_win)
    assert(type(on_win) == "function", "race expects on_win callback")
    local wrapped = {}
    for i, op in ipairs(ops) do
        wrapped[i] = op:wrap(function(...)
            return on_win(i, ...)
        end)
    end
    return choice(unpack(wrapped))
end

--- Race ops and return (index, ...results...) of the winner.
---@param ops Op[]
---@return Op
local function first_ready(ops)
    return race(ops, function(i, ...)
        return i, ...
    end)
end

--- Choice over a table of named ops, returning (name, ...results...).
---@param arms table<string, Op>
---@return Op
local function named_choice(arms)
    local ops, names = {}, {}
    for name, op in pairs(arms) do
        names[#names + 1] = name
        ops[#ops + 1]     = op
    end
    return race(ops, function(i, ...)
        return names[i], ...
    end)
end

--- Choice between two ops, returning (boolean, ...results...).
--- Returns true for the first op, false for the second.
---@param op_true Op
---@param op_false Op
---@return Op
local function boolean_choice(op_true, op_false)
    return race({ op_true, op_false }, function(i, ...)
        if i == 1 then
            return true, ...
        else
            return false, ...
        end
    end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
    perform_raw    = perform,
    new_primitive  = new_primitive,
    choice         = choice,
    guard          = guard,
    with_nack      = with_nack,
    bracket        = bracket,
    always         = always,
    never          = never,
    Op             = Op,
    race           = race,
    first_ready    = first_ready,
    named_choice   = named_choice,
    boolean_choice = boolean_choice,
}
