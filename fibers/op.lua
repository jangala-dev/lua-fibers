--- fibers.op module
-- Provides Concurrent ML style operations for managing concurrency.
-- Events are CML-style: they can be primitive, choices, guards, with_nack,
-- or wrapped. Synchronization compiles an event tree into primitive leaves.

local fiber  = require 'fibers.fiber'

local unpack = table.unpack or unpack -- luacheck: ignore
local pack   = table.pack or function(...) return { n = select("#", ...), ... } end -- luacheck: ignore

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
-- try_fn()  -> success:boolean, ...
-- block_fn(suspension, wrap_fn) sets up async completion.
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
            for _, sub in ipairs(ev.events) do events[#events + 1] = sub end
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
--   { try_fn, block_fn, wrap, nack_cond }
-- where wrap(...) is the final post-processing function for this leaf.
----------------------------------------------------------------------

local function compile_event(ev, outer_wrap, out, nack_cond)
    out        = out or {}
    outer_wrap = outer_wrap or id_wrap

    local kind = ev.kind

    if kind == 'choice' then
        for _, sub in ipairs(ev.events) do
            compile_event(sub, outer_wrap, out, nack_cond)
        end

    elseif kind == 'guard' then
        local inner = ev.builder()
        compile_event(inner, outer_wrap, out, nack_cond)

    elseif kind == 'with_nack' then
        local cond    = new_cond()
        local nack_ev = cond.wait_op() -- Event
        local inner   = ev.builder(nack_ev)
        compile_event(inner, outer_wrap, out, cond)

    elseif kind == 'wrap' then
        local f         = ev.wrap_fn
        local new_outer = function(...)
            return outer_wrap(f(...))
        end
        compile_event(ev.inner, new_outer, out, nack_cond)

    else -- 'prim'
        local final_wrap = function(...)
            return outer_wrap(ev.wrap_fn(...))
        end
        out[#out + 1] = {
            try_fn    = ev.try_fn,
            block_fn  = ev.block_fn,
            wrap      = final_wrap,
            nack_cond = nack_cond,
        }
    end

    return out
end

----------------------------------------------------------------------
-- Nack triggering and non-blocking attempt
----------------------------------------------------------------------

local function trigger_nacks(ops, winner_index)
    local winner_cond = winner_index and ops[winner_index].nack_cond or nil
    local seen = {}
    for _, op in ipairs(ops) do
        local cond = op.nack_cond
        if cond and cond ~= winner_cond and not seen[cond] then
            seen[cond] = true
            cond.signal()
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
-- Event methods: perform & perform_alt
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

    -- Find the winning leaf by matching wrap function.
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
