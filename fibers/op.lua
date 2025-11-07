--- fibers.op module
-- Provides Concurrent ML style operations for managing concurrency.
-- Events are CML-style: primitive leaves, choices, guards, with_nack,
-- and wraps. Synchronization compiles an event tree into primitive leaves.

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

-- with_nack g: delayed event; g(nack_ev) evaluated once per synchronization.
-- nack_ev is an Event that becomes ready iff this with_nack is *not* chosen.
local function with_nack(g)
    return setmetatable({ kind = 'with_nack', builder = g }, Event)
end

-- Wrap event with a post-processing function f.
-- This is another node in the tree; composed at compile time.
function Event:wrap(f)
    return setmetatable(
        { kind = 'wrap', inner = self, wrap_fn = f },
        Event
    )
end

----------------------------------------------------------------------
-- Simple one-shot condition primitive (used for with_nack; also exported)
----------------------------------------------------------------------

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
                suspension:complete(wrap_fn)
            else
                state.waiters[#state.waiters + 1] = suspension:complete_task(wrap_fn)
            end
        end
        return new_base_op(nil, try, block)
    end

    local function signal()
        if state.triggered then return end
        state.triggered = true
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

----------------------------------------------------------------------
-- Compile an event tree into primitive leaves
--
-- A compiled leaf has:
--   {
--     try_fn,
--     block_fn,
--     wrap,          -- final wrap function for this leaf
--     nacks = {...}, -- list of all active with_nack conds on this path
--   }
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
        local nack_ev = cond.wait_op() -- Event
        local inner   = ev.builder(nack_ev)
        -- Extend the current nack list for this subtree
        local child_nacks             = { unpack(nacks) }
        child_nacks[#child_nacks + 1] = cond

        compile_event(inner, outer_wrap, out, child_nacks)

    elseif kind == 'wrap' then
        local f         = ev.wrap_fn
        local new_outer = function(...)
            return outer_wrap(f(...))
        end
        compile_event(ev.inner, new_outer, out, nacks)

    else -- 'prim'
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

-- Signal all with_nack conds that belong exclusively to losing arms.
local function trigger_nacks(ops, winner_index)
    -- Build a set of conds to *skip* (all on the winner path).
    local winner = {}
    if winner_index then
        local wnacks = ops[winner_index].nacks
        if wnacks then
            for i = 1, #wnacks do
                winner[wnacks[i]] = true
            end
        end
    end

    -- Signal each losing cond once.
    local signaled = {}
    for i = 1, #ops do
        local nacks = ops[i].nacks
        if nacks then
            for j = 1, #nacks do
                local cond = nacks[j]
                if cond and not winner[cond] and not signaled[cond] then
                    signaled[cond] = true
                    cond.signal()
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
-- Event methods: perform, poll, perform_alt
----------------------------------------------------------------------

-- Perform this event (primitive or composite), possibly blocking.
function Event:perform()
    local ops = compile_event(self)

    -- Fast path: non-blocking attempt.
    local idx, retval = try_ready(ops)
    if idx then
        trigger_nacks(ops, idx)
        return apply_wrap(ops[idx].wrap, retval)
    end

    -- Slow path: block on all compiled leaves.
    local suspended = pack(fiber.suspend(block_choice_op, ops))
    local wrap      = suspended[1]

    -- Find the winning leaf by matching its wrap function.
    local winner_index
    for i, op in ipairs(ops) do
        if op.wrap == wrap then
            winner_index = i
            break
        end
    end
    trigger_nacks(ops, winner_index)

    return wrap(unpack(suspended, 2, suspended.n))
end

-- poll: non-blocking synchronization attempt.
-- Returns (true, ...results) if some arm commits, or (false) otherwise.
function Event:poll()
    local ops = compile_event(self)
    local idx, retval = try_ready(ops)
    if not idx then return false end
    trigger_nacks(ops, idx)
    return true, apply_wrap(ops[idx].wrap, retval)
end

-- perform_alt: non-blocking; if no arm ready, call f().
function Event:perform_alt(f)
    local res = pack(self:poll())
    if res[1] then
        return unpack(res, 2, res.n)
    end
    return f()
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
    new_base_op = new_base_op, -- primitive event constructor
    choice      = choice,
    guard       = guard,
    with_nack   = with_nack,
    new_cond    = new_cond,
}
