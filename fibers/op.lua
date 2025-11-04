--- fibers.op module
-- Provides Concurrent ML style operations for managing concurrency.
-- @module fibers.op

local fiber = require 'fibers.fiber'

local unpack = table.unpack or unpack  -- luacheck: ignore -- Compatibility fallback
local pack = table.pack or function(...) -- luacheck: ignore -- Compatibility fallback
    return { n = select("#", ...), ... }
end

local function id_wrap(...)
    return ...
end

local Suspension = {}
Suspension.__index = Suspension

local CompleteTask = {}
CompleteTask.__index = CompleteTask

function Suspension:waiting() return self.state == 'waiting' end

function Suspension:complete(wrap, ...)
    assert(self:waiting())
    self.state = 'synchronized'
    self.wrap = wrap
    self.val = {...}
    self.sched:schedule(self)
end

function Suspension:complete_and_run(wrap, ...)
    assert(self:waiting())
    self.state = 'synchronized'
    return self.fiber:resume(wrap, ...)
end

function Suspension:complete_task(wrap, ...)
    return setmetatable({ suspension = self, wrap = wrap, val = {...} }, CompleteTask)
end

function Suspension:run()
    assert(not self:waiting())
    return self.fiber:resume(self.wrap, unpack(self.val))
end

local function new_suspension(sched, fib)
    return setmetatable(
        { state = 'waiting', sched = sched, fiber = fib },
        Suspension)
end

--- A complete task is a task that when run, completes a suspension, if
--- the suspension hasn't been completed already.  There can be multiple
--- complete tasks for a given suspension, if the suspension can complete
--- in multiple ways (e.g. via a choice op).
function CompleteTask:run()
    if self.suspension:waiting() then
        -- Use complete-and-run so that the fiber runs in this turn.
        self.suspension:complete_and_run(self.wrap, unpack(self.val))
    end
end

--- A complete task can also be cancelled, which makes it complete with a
--- call to "error".
-- @param reason A string describing the reason for the cancellation
function CompleteTask:cancel(reason)
    if self.suspension:waiting() then
        self.suspension:complete(error, reason or 'cancelled')
    end
end

--- BaseOp class
-- Represents a base operation.
-- @type BaseOp
local BaseOp = {
    wrap_fn = id_wrap
}
BaseOp.__index = BaseOp

--- Create a new base operation.
-- @tparam function wrap_fn The wrap function.
-- @tparam function try_fn The try function.
-- @tparam function block_fn The block function.
-- @treturn BaseOp The created base operation.
local function new_base_op(wrap_fn, try_fn, block_fn)
    return setmetatable(
        { wrap_fn = wrap_fn, try_fn = try_fn, block_fn = block_fn },
        BaseOp)
end

--- ChoiceOp class
-- Represents a choice operation.
-- @type ChoiceOp
local ChoiceOp = {}
ChoiceOp.__index = ChoiceOp
local function new_choice_op(base_ops)
    return setmetatable(
        { base_ops = base_ops },
        ChoiceOp)
end

--- Create a choice operation from the given operations.
-- @tparam vararg ops The operations.
-- @treturn ChoiceOp The created choice operation.
local function choice(...)
    local ops = {}
    -- Build a flattened list of choices that are all base ops.
    for _, op in ipairs({ ... }) do
        if op.base_ops then
            for _, base_op in ipairs(op.base_ops) do table.insert(ops, base_op) end
        else
            table.insert(ops, op)
        end
    end
    if #ops == 1 then return ops[1] end
    return new_choice_op(ops)
end

--- Wrap the base operation with the given function.
-- @tparam function f The function.
-- @treturn BaseOp The created base operation.
function BaseOp:wrap(f)
    local new              = new_base_op(
        function(...)
            return f(self.wrap_fn(...))
        end,
        self.try_fn,
        self.block_fn
    )
    -- Preserve any delayed-event builders on the new base op.
    new._guard_builder     = self._guard_builder
    new._with_nack_builder = self._with_nack_builder
    return new
end

--- Wrap the choice operation with the given function.
-- @tparam function f The function.
-- @treturn ChoiceOp The created choice operation.
function ChoiceOp:wrap(f)
    local ops = {}
    for _, op in ipairs(self.base_ops) do table.insert(ops, op:wrap(f)) end
    return new_choice_op(ops)
end

-- Simple one-shot condition primitive: all current and future waiters
-- wake once signal() is called. Used by fibers.cond as a thin wrapper.
local function new_cond()
    local state = {
        triggered = false,
        waiters   = {}, -- array of CompleteTask
    }

    local function wait_op()
        local function try()
            return state.triggered
        end
        local function block(suspension, wrap_fn)
            if state.triggered then
                -- Already signalled: complete immediately.
                suspension:complete(wrap_fn)
            else
                -- Store a CompleteTask; we'll schedule it on signal().
                table.insert(state.waiters, suspension:complete_task(wrap_fn))
            end
        end
        return new_base_op(nil, try, block)
    end

    local function signal()
        if state.triggered then return end
        state.triggered = true
        -- Wake all waiters (if still waiting) on their schedulers.
        for i = 1, #state.waiters do
            local task = state.waiters[i]
            state.waiters[i] = nil
            if task and task.suspension and task.suspension:waiting() then
                task.suspension.sched:schedule(task)
            end
        end
    end

    return {
        wait_op = wait_op,
        signal  = signal,
    }
end
local function new_delayed_base_op(builder_field, g, label)
    local base = new_base_op(
        id_wrap,
        function() return false end,
        function()
            error(label .. " block_fn should never be called directly")
        end
    )
    base[builder_field] = g
    return base
end
--- CML-style guard: delayed event. g() is evaluated once per
--- synchronization (per call to :perform / :perform_alt, or when used
--- inside a ChoiceOp:perform), and the event it returns participates
--- fully in the choice.
local function guard(g)
    return new_delayed_base_op("_guard_builder", g, "guard")
end

-- CML-style withNack: delayed event with a negative-ack event.
-- g(nack_ev) is evaluated once per synchronization. If some *other*
-- event in the same synchronization commits, nack_ev becomes enabled.
local function with_nack(g)
    return new_delayed_base_op("_with_nack_builder", g, "with_nack")
end
-- Resolve a single event (BaseOp or ChoiceOp) into a list of BaseOps,
-- composing an outer wrap on top if provided.
local function resolve_event(ev, outer_wrap, out)
    if not out then out = {} end
    outer_wrap = outer_wrap or id_wrap

    if ev.base_ops then
        -- ev is a ChoiceOp: resolve each arm with the same outer_wrap.
        for _, b in ipairs(ev.base_ops) do
            resolve_event(b, outer_wrap, out)
        end
    elseif ev._guard_builder then
        -- ev is a guard: evaluate builder once for this synchronization,
        -- then resolve the resulting event.
        local inner_ev = ev._guard_builder()

        local guard_wrap = ev.wrap_fn
        local composed_outer = function(...)
            return outer_wrap(guard_wrap(...))
        end

        resolve_event(inner_ev, composed_outer, out)
    elseif ev._with_nack_builder then
        -- with_nack: create a per-sync condition and nack event.
        local cond           = new_cond()
        local nack_ev        = cond.wait_op() -- this is the nack event g() sees
        local inner_ev       = ev._with_nack_builder(nack_ev)

        local with_wrap      = ev.wrap_fn
        local composed_outer = function(...)
            return outer_wrap(with_wrap(...))
        end

        -- Flatten the inner event, tagging all resulting ops with this cond.
        local start_index    = #out + 1
        resolve_event(inner_ev, composed_outer, out)
        for i = start_index, #out do
            out[i]._nack_cond = cond
        end
    else
        -- Plain BaseOp: compose inner wrap under outer_wrap.
        local inner_wrap = ev.wrap_fn
        local composed_wrap = function(...)
            return outer_wrap(inner_wrap(...))
        end

        table.insert(out, new_base_op(composed_wrap, ev.try_fn, ev.block_fn))
    end

    return out
end

local function resolve_choice_ops(base_ops)
    local resolved = {}
    for _, op in ipairs(base_ops) do
        resolve_event(op, nil, resolved)
    end
    return resolved
end

-- Try once to commit on this event (BaseOp, ChoiceOp, or delayed event),
-- non-blocking. Returns winner_op, retval_pack, ops | nil.
local function try_once(ev)
    -- Normalise to a list of logical events.
    local logicals = ev.base_ops and ev.base_ops or { ev }

    -- Expand guards / with_nack / nested choices into plain BaseOps.
    local ops = resolve_choice_ops(logicals)
    local n = #ops
    if n == 0 then return nil, nil, ops end

    local base = math.random(n)
    for i = 1, n do
        local op = ops[((i + base) % n) + 1]
        local retval = pack(op.try_fn())
        if retval[1] then return op, retval, ops end
    end
    return nil, nil, ops
end
-- Trigger nack events for all *losing* with_nack arms in this choice.
local function trigger_nacks(ops, winner)
    local winner_cond = winner and winner._nack_cond or nil
    local seen = {}
    for _, op in ipairs(ops) do
        local cond = op._nack_cond
        if cond and cond ~= winner_cond and not seen[cond] then
            seen[cond] = true
            cond.signal()
        end
    end
end
-- Public CML-style poll: non-blocking synchronization attempt.
-- Returns (true, ...results) if some arm commits, or (false) otherwise.
local function poll(ev)
    local winner, retval, ops = try_once(ev)
    if not winner then return false end
    trigger_nacks(ops, winner)
    return true, winner.wrap_fn(unpack(retval, 2, retval.n))
end

local function block_choice_op(sched, fib, ops)
    local suspension = new_suspension(sched, fib)
    for _, op in ipairs(ops) do
        local choice_wrap = op.wrap_fn
        op._choice_wrap = choice_wrap
        op.block_fn(suspension, choice_wrap)
    end
end

--- Perform the choice operation.
-- @treturn vararg The value returned by the operation.
function ChoiceOp:perform()
    -- Fast path: non-blocking attempt using the shared core.
    local winner, retval, ops = try_once(self)
    if winner then
        trigger_nacks(ops, winner)
        return winner.wrap_fn(unpack(retval, 2, retval.n))
    end

    -- Slow path: block on all resolved ops.
    local suspended = pack(fiber.suspend(block_choice_op, ops))
    local wrap = suspended[1]
    local winner_after
    for _, op in ipairs(ops) do
        if op._choice_wrap == wrap then
            winner_after = op
            break
        end
    end
    trigger_nacks(ops, winner_after)
    return wrap(unpack(suspended, 2, suspended.n))
end

--- Perform the base operation.
-- We treat any single event (including guards/with_nack) as a 1-arm
-- choice so it shares the exact same resolution / blocking path as
-- ChoiceOp:perform.
function BaseOp:perform()
    return new_choice_op({ self }):perform()
end

--- Perform the choice operation or return the result of the function if the operation cannot be performed.
-- @tparam function f The function.
-- @treturn vararg The value returned by the operation or the function.
function ChoiceOp:perform_alt(f)
    local ret = pack(poll(self))
    local ready = ret[1]
    if ready then
        return unpack(ret, 2, ret.n)
    end
    return f()
end

--- Perform the base operation or return the result of the function if the operation cannot be performed.
-- @tparam function f The function.
-- @treturn vararg The value returned by the operation or the function.
function BaseOp:perform_alt(f)
    return new_choice_op({ self }):perform_alt(f)
end

return {
    new_base_op = new_base_op,
    choice      = choice,
    guard       = guard,
    new_cond    = new_cond,
    with_nack   = with_nack,
    poll        = poll,
}
