--- fibers.op module
-- Provides Concurrent ML style operations for managing concurrency.
-- Events are CML-style: primitive leaves, choices, guards, with_nack,
-- wraps, and an extra abort combinator (on_abort).
--
-- Core event AST kinds:
--   prim      : primitive leaf { try_fn, block_fn, wrap_fn }
--   choice    : non-empty list of events
--   guard     : delayed event builder (run once per sync)
--   with_nack : CML-style nack combinator
--   wrap      : post-commit mapper (composed at compile time)
--   abort     : attach abort handler to an event (run if this arm loses)
--
-- Semantics sketch
-- ----------------
-- We keep CML-style semantics for with_nack:
--   - with_nack g gets a nack event that becomes enabled iff the
--     *entire* resulting event loses in an enclosing choice.
--   - nested with_nack behaves correctly: outer nacks only fire when
--     the outer event loses, not when internal subchoices resolve.
--
-- `on_abort(ev, f)` is implemented in terms of the same "nack" machinery:
--   - each abort scope behaves like a nack-cond whose signal() runs f().
--   - after a choice commits, we figure out which conds are associated
--     exclusively with losing arms and signal those once.
--
-- We also provide:
--   - bracket(acquire, release, use): RAII-style resource protocol.
--   - else_next_turn(ev, fallback_ev): biased choice; prefer ev, but
--     if it doesn't commit "by next turn", abort it cleanly and run
--     fallback_ev (in a separate sync).

local fiber  = require 'fibers.fiber'

local unpack = rawget(table, "unpack") or _G.unpack
local pack   = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

local function id_wrap(...) return ... end

----------------------------------------------------------------------
-- Suspensions and completion tasks
----------------------------------------------------------------------

local Suspension = {}
Suspension.__index = Suspension

local CompleteTask = {}
CompleteTask.__index = CompleteTask

function Suspension:waiting()
    return self.state == 'waiting'
end

function Suspension:complete(wrap, ...)
    assert(self:waiting())
    self.state = 'synchronized'
    self.wrap  = wrap
    self.val   = { ... }
    self.sched:schedule(self)
end

function Suspension:complete_and_run(wrap, ...)
    assert(self:waiting())
    self.state = 'synchronized'
    return self.fiber:resume(wrap, ...)
end

function Suspension:complete_task(wrap, ...)
    return setmetatable({ suspension = self, wrap = wrap, val = { ... } }, CompleteTask)
end

function Suspension:run()
    assert(not self:waiting())
    return self.fiber:resume(self.wrap, unpack(self.val))
end

local function new_suspension(sched, fib)
    return setmetatable({ state = 'waiting', sched = sched, fiber = fib }, Suspension)
end

-- A CompleteTask completes a suspension (if still waiting) when run.
function CompleteTask:run()
    if self.suspension:waiting() then
        self.suspension:complete_and_run(self.wrap, unpack(self.val))
    end
end

-- A CompleteTask can be cancelled, completing with an error.
function CompleteTask:cancel(reason)
    if self.suspension:waiting() then
        self.suspension:complete(error, reason or 'cancelled')
    end
end

----------------------------------------------------------------------
-- Event type (unifies primitive and composite events)
--
-- kind = 'prim'      : { try_fn, block_fn, wrap_fn }
-- kind = 'choice'    : { events = { Event, ... } }
-- kind = 'guard'     : { builder = function() -> Event }
-- kind = 'with_nack' : { builder = function(nack_ev) -> Event }
-- kind = 'wrap'      : { inner = Event, wrap_fn = f }
-- kind = 'abort'     : { inner = Event, abort_fn = f }
----------------------------------------------------------------------

local Event = {}
Event.__index = Event

-- Primitive event (leaf).
--   try_fn() -> success:boolean, ...
--   block_fn(suspension, wrap_fn) sets up async completion.
local function new_base_op(wrap_fn, try_fn, block_fn)
    return setmetatable(
        {
            kind     = 'prim',
            wrap_fn  = wrap_fn or id_wrap,
            try_fn   = try_fn,
            block_fn = block_fn,
        },
        Event
    )
end

-- Choice event: non-empty list of sub-events.
local function choice(...)
    local events = {}
    for _, ev in ipairs({ ... }) do
        if ev.kind == 'choice' then
            for _, sub in ipairs(ev.events) do
                events[#events + 1] = sub
            end
        else
            events[#events + 1] = ev
        end
    end
    if #events == 1 then return events[1] end
    return setmetatable({ kind = 'choice', events = events }, Event)
end

-- guard g: delayed event; g() evaluated once per synchronization.
local function guard(g)
    return setmetatable({ kind = 'guard', builder = g }, Event)
end

-- CML-style with_nack: builder gets a nack event that becomes ready
-- iff this event participates in a choice and *loses*.
local function with_nack(g)
    return setmetatable({ kind = 'with_nack', builder = g }, Event)
end

-- next_turn_op: primitive event that is never ready in the fast path;
-- if forced to block, it completes itself on the *next scheduler turn*.
local function next_turn_op()
    local function try()
        return false
    end

    local function block(suspension, wrap_fn)
        local task = suspension:complete_task(wrap_fn)
        suspension.sched:schedule(task)
    end

    return new_base_op(nil, try, block)
end

local function always(value)
    return new_base_op(nil,
        function() return true, value end,
        function() error("always: block_fn should never run") end)
end

local function never()
    -- An event that never becomes ready
    return new_base_op(nil,
        function() return false end,
        function() end)
end

function Event:or_else(fallback_thunk)
    return choice(
        self,
        next_turn_op():wrap(function()
            return fallback_thunk()
        end)
    )
end

-- Wrap event with a post-processing function f (commit phase).
-- This is another node in the tree; composed at compile time.
function Event:wrap(f)
    return setmetatable(
        { kind = 'wrap', inner = self, wrap_fn = f },
        Event
    )
end

-- Attach an abort handler to this event.
-- f() is run iff this event participates in a choice and *does not win*.
function Event:on_abort(f)
    assert(type(f) == 'function', "on_abort expects a function")
    return setmetatable(
        { kind = 'abort', inner = self, abort_fn = f },
        Event
    )
end

----------------------------------------------------------------------
-- Simple one-shot condition primitive (used for with_nack; also exported)
----------------------------------------------------------------------

local function new_cond(opts)
    local state = {
        triggered = false,
        waiters   = {},        -- optional
        abort_fn  = opts and opts.abort_fn or nil,
    }

    local function wait_op()
        assert(not state.abort_fn, "abort-only cond has no wait_op")
        local function try()
            return state.triggered
        end
        local function block(suspension, wrap_fn)
            if state.triggered then
                suspension:complete(wrap_fn)
            else
                state.waiters[#state.waiters + 1] =
                    suspension:complete_task(wrap_fn)
            end
        end
        return new_base_op(nil, try, block)
    end

    local function signal()
        if state.triggered then return end
        state.triggered = true
        -- wake waiters, if any
        for i = 1, #state.waiters do
            local task = state.waiters[i]
            state.waiters[i] = nil
            if task
                and task.suspension
                and task.suspension:waiting()
            then
                task.suspension.sched:schedule(task)
            end
        end
        -- fire abort handler, if any
        if state.abort_fn then
            pcall(state.abort_fn)
        end
    end

    return {
        wait_op = state.abort_fn and nil or wait_op,
        signal  = signal,
    }
end

----------------------------------------------------------------------
-- Compile an event tree into primitive leaves
--
-- A compiled leaf has:
--   {
--     try_fn,
--     block_fn,
--     wrap,          -- final wrap function for this leaf
--     nacks = {...}, -- list of all active nack/abort conds on this path
--   }
--
-- Semantics:
--   - Each with_nack or abort node adds a cond to the nacks list.
--   - After a winner leaf is chosen, we find which conds appear only
--     on losing paths and signal those once (CML-style nack).
----------------------------------------------------------------------

local function compile_event(ev, outer_wrap, out, nacks)
    out        = out or {}
    outer_wrap = outer_wrap or id_wrap
    nacks      = nacks or {}

    local kind = ev.kind

    if kind == 'choice' then
        for _, sub in ipairs(ev.events) do
            compile_event(sub, outer_wrap, out, nacks)
        end

    elseif kind == 'guard' then
        local inner = ev.builder()
        compile_event(inner, outer_wrap, out, nacks)

    elseif kind == 'with_nack' then
        local cond    = new_cond()
        local nack_ev = cond.wait_op()
        local inner   = ev.builder(nack_ev)

        local child_nacks = { unpack(nacks) }
        child_nacks[#child_nacks + 1] = cond
        compile_event(inner, outer_wrap, out, child_nacks)

    elseif kind == 'wrap' then
        local f         = ev.wrap_fn
        local new_outer = function(...)
            return outer_wrap(f(...))
        end
        compile_event(ev.inner, new_outer, out, nacks)

    elseif kind == 'abort' then
        local cond        = new_cond{ abort_fn = ev.abort_fn }
        local child_nacks = { unpack(nacks) }
        child_nacks[#child_nacks + 1] = cond
        compile_event(ev.inner, outer_wrap, out, child_nacks)

    else -- 'prim'
        -- Each leaf gets a unique final_wrap closure so identity comparison in
        local final_wrap = function(...)
            return outer_wrap(ev.wrap_fn(...))
        end
        out[#out + 1] = {
            try_fn   = ev.try_fn,
            block_fn = ev.block_fn,
            wrap     = final_wrap,
            nacks    = nacks,
        }
    end

    return out
end

----------------------------------------------------------------------
-- Nack triggering and non-blocking attempt
----------------------------------------------------------------------

-- Signal all conds that belong exclusively to losing arms.
-- This is the original CML-style logic:
--   - Build set of nacks on the winner path.
--   - For each loser leaf, signal any nacks not in the winner set.
--   - Each cond object is responsible for idempotence.
local function trigger_nacks(ops, winner_index)
    assert(winner_index, "trigger_nacks: no winner_index (internal error)")

    local winner_set = {}
    local wnacks     = ops[winner_index].nacks
    if wnacks then
        for i = 1, #wnacks do
            winner_set[wnacks[i]] = true
        end
    end

    local signaled = {}
    for i = 1, #ops do
        if i ~= winner_index then
            local nacks = ops[i].nacks
            if nacks then
                for j = #nacks, 1, -1 do
                    local cond = nacks[j]
                    if cond
                        and not winner_set[cond]
                        and not signaled[cond]
                    then
                        signaled[cond] = true
                        cond.signal()
                    end
                end
            end
        end
    end
end

-- Try once to find a ready leaf in ops (random probe order).
-- Returns winner_index, retval_pack | nil.
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

-- Apply a leaf's wrap to its retval_pack.
local function apply_wrap(wrap, retval)
    return wrap(unpack(retval, 2, retval.n))
end

----------------------------------------------------------------------
-- Blocking choice path
----------------------------------------------------------------------

local function block_choice_op(sched, fib, ops)
    local suspension = new_suspension(sched, fib)
    for _, op in ipairs(ops) do
        op.block_fn(suspension, op.wrap)
    end
end

----------------------------------------------------------------------
-- Event methods: perform, perform_alt
----------------------------------------------------------------------

-- Perform this event (primitive or composite), possibly blocking.
local function perform(ev)
    local leaves = compile_event(ev)

    -- Fast path
    local idx, retval = try_ready(leaves)
    if idx then
        trigger_nacks(leaves, idx)
        return apply_wrap(leaves[idx].wrap, retval)
    end

    -- Slow path
    local suspended = pack(fiber.suspend(block_choice_op, leaves))
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
-- bracket : (acquire, release, use) -> 'a event
--
-- acquire()          : -> resource
-- release(resource, aborted:boolean)
-- use(resource)      : -> Event (the main action)
--
-- Semantics:
--   * acquire is run once, at sync time (inside a guard).
--   * if the resulting event `ev` WINS:
--       - its result is returned
--       - release(res, false) is called (best-effort, pcall)
--   * if the resulting event PARTICIPATES in a choice but LOSES:
--       - release(res, true) is called (via on_abort / nack machinery)
--
-- This is *purely an Event combinator*; no new fiber is spawned.
----------------------------------------------------------------------

local function bracket(acquire, release, use)
  return guard(function()
    local res = acquire()
    local ok, ev = pcall(use, res)
    if not ok then
      pcall(release, res, true)     -- ensure cleanup on builder failure
      error(ev)
    end
    return ev
      :wrap(function(...)
        pcall(release, res, false)
        return ...
      end)
      :on_abort(function()
        pcall(release, res, true)
      end)
  end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
    perform        = perform,
    new_base_op    = new_base_op, -- primitive event constructor
    choice         = choice,
    guard          = guard,
    with_nack      = with_nack,
    new_cond       = new_cond,
    bracket        = bracket,
    always         = always,
    never          = never,
    -- Event instances have methods: wrap, on_abort.
}
