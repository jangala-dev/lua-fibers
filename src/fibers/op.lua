--- fibers.op module
-- Concurrent ML style operations for managing concurrency.
--
-- Events are CML-style: primitive leaves, choices, guards, with_nack,
-- wraps, and an abort combinator (on_abort).
--
-- Core event AST kinds:
--   prim    : primitive leaf { try_fn, block_fn, wrap_fn }
--   choice  : non-empty list of events
--   guard   : delayed event builder (run once per sync)
--   with_nack : CML-style nack combinator
--   wrap    : post-commit mapper (composed at compile time)
--   abort   : attach abort handler to an event (run if this arm loses)
--
-- Important design note:
--   This module is *exception-neutral*. It does not interpret Lua
--   errors as part of event semantics. Any uncaught error in a wrap
--   or primitive is treated as a bug and will be surfaced by the
--   surrounding scope / fibre machinery.

local runtime  = require 'fibers.runtime'

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

-- A CompleteTask can be cancelled. In the non-exceptional model, this
-- completes the suspension with a special "cancel" wrap that returns
-- a tagged result (false, reason) rather than raising.
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

-- forward declaration so compile_event can call perform if needed in
-- future extension; currently perform does not use exceptions.
local perform

-- Primitive event (leaf).
--   try_fn() -> success:boolean, ...
--   block_fn(suspension, wrap_fn) sets up async completion.
local function new_primitive(wrap_fn, try_fn, block_fn)
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

local function always(...)
    local results = { ... }
    local function try()
        return true, unpack(results)
    end
    local function block() error("always: block_fn should never run") end  -- never reached
    return new_primitive(nil, try, block)
end

local function never()
    -- An event that never becomes ready
    return new_primitive(nil,
        function() return false end,
        function() end)
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
        waiters   = {},        -- list of { suspension = ..., wrap = ... }
        abort_fn  = opts and opts.abort_fn or nil,
    }

    local function wait_op()
        assert(not state.abort_fn, "abort-only cond has no wait_op")

        local function try()
            return state.triggered
        end

        local function block(suspension, wrap_fn)
            if state.triggered then
                -- Already triggered: complete immediately via the scheduler.
                suspension:complete(wrap_fn)
            else
                -- Record this suspension + wrap for later signalling.
                state.waiters[#state.waiters + 1] = {
                    suspension = suspension,
                    wrap       = wrap_fn,
                }
            end
        end

        return new_primitive(nil, try, block)
    end

    local function signal()
        if state.triggered then return end
        state.triggered = true

        -- Complete all recorded waiters via the scheduler.
        for i = 1, #state.waiters do
            local remote = state.waiters[i]
            state.waiters[i] = nil

            if remote
            and remote.suspension
            and remote.suspension:waiting()
            then
                remote.suspension:complete(remote.wrap)
            end
        end

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
--   - wrap nodes compose their functions into the final wrap.
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
        local function wrapped(...)
            -- No exception machinery here; any Lua error is treated
            -- as a bug and handled by the surrounding scope/fibre.
            return outer_wrap(ev.wrap_fn(...))
        end

        out[#out + 1] = {
            try_fn   = ev.try_fn,
            block_fn = ev.block_fn,
            wrap     = wrapped,
            nacks    = nacks,
        }
    end

    return out
end

----------------------------------------------------------------------
-- Nack triggering and non-blocking attempt
----------------------------------------------------------------------

-- Signal all conds that belong exclusively to losing arms.
--   - Build set of nacks on the winner path.
--   - For each loser leaf, signal any nacks not in the winner set.
--   - Each cond object is responsible for idempotence.
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
-- or_else: biased, non-blocking choice
----------------------------------------------------------------------

function Event:or_else(fallback_thunk)
    assert(type(fallback_thunk) == "function", "or_else expects a function")

    return guard(function()
        -- Compile `self` once for this synchronisation.
        local leaves = compile_event(self)

        -- Non-blocking attempt to commit to `self`.
        local idx, retval = try_ready(leaves)
        if idx then
            -- Normal CML semantics: `self` wins, fire nacks for losers.
            trigger_nacks(leaves, idx)
            local results = { apply_wrap(leaves[idx].wrap, retval) }
            return always(unpack(results))
        end

        -- No leaf of `self` is ready now → `self` loses as a whole.
        -- Fire all nacks/abort handlers hanging off `self`.
        trigger_nacks(leaves, nil)

        local results = { fallback_thunk() }
        return always(unpack(results))
    end)
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
-- Event methods: perform
----------------------------------------------------------------------

-- Perform this event (primitive or composite), possibly blocking.
-- Any Lua error raised during wraps or primitives is not caught here;
-- it will abort the current fibre and be handled by the scope layer.
perform = function(ev)
    local leaves = compile_event(ev)

    -- Fast path: non-blocking attempt.
    local idx, retval = try_ready(leaves)
    if idx then
        trigger_nacks(leaves, idx)
        return apply_wrap(leaves[idx].wrap, retval)
    end

    -- Slow path: we now block all leaves using block_choice_op.
    local suspended = pack(runtime.suspend(block_choice_op, leaves))
    local wrap      = suspended[1]

    -- Identify winning leaf by its wrap function, if any.
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
-- finally : (ev, cleanup) -> ev'
--
-- cleanup(aborted:boolean)
--
-- Semantics:
--   * on normal post-sync completion:
--       cleanup(false) is called (best-effort, protected).
--   * if the event *loses* in a choice (via on_abort):
--       cleanup(true) is called (best-effort, protected).
--
-- Exceptions from ev's wrap or primitives are not intercepted here;
-- they are handled by the surrounding scope as fibre failures.
----------------------------------------------------------------------

function Event:finally(cleanup)
    assert(type(cleanup) == "function", "finally expects a function")

    -- Success path: only runs if this event wins and completes its wraps
    -- without raising.
    local function success_wrap(...)
        cleanup(false)
        return ...
    end

    -- Abort path: runs if this event participates in a choice and loses.
    local function abort_action()
        cleanup(true)
    end

    return self:wrap(success_wrap):on_abort(abort_action)
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
-- This combinator does not interpret Lua errors from acquire/use as
-- normal control flow. Any uncaught error there fails the running
-- fibre and is recorded at the scope level.
----------------------------------------------------------------------

local function bracket(acquire, release, use)
    assert(type(acquire) == "function", "bracket: acquire must be a function")
    assert(type(release) == "function", "bracket: release must be a function")
    assert(type(use) == "function", "bracket: use must be a function")

    return guard(function()
        local res = acquire()

        -- If use(res) throws, that is a bug; scope machinery will handle it.
        local ev = use(res)

        -- Success path: event wins and completes → release(res, false) once.
        local wrapped = ev:wrap(function(...)
            release(res, false)
            return ...
        end)

        -- Losing path: event participates in a choice but loses → release(res, true) once.
        return wrapped:on_abort(function()
            release(res, true)
        end)
    end)
end

----------------------------------------------------------------------
-- Higher-level choice helpers (built entirely from choice + wrap)
----------------------------------------------------------------------

local function race(events, on_win)
    assert(type(on_win) == "function", "race expects on_win callback")
    local wrapped = {}
    for i, ev in ipairs(events) do
        wrapped[i] = ev:wrap(function(...)
            return on_win(i, ...)
        end)
    end
    return choice(unpack(wrapped))
end

local function first_ready(events)
    return race(events, function(i, ...)
        return i, ...
    end)
end

local function named_choice(arms)
    -- arms is a map { name = Event, ... }
    local events, names = {}, {}
    for name, ev in pairs(arms) do
        names[#names + 1]   = name
        events[#events + 1] = ev
    end
    return race(events, function(i, ...)
        return names[i], ...
    end)
end

local function boolean_choice(ev_true, ev_false)
    return race({ ev_true, ev_false }, function(i, ...)
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
    new_primitive  = new_primitive, -- primitive event constructor
    choice         = choice,
    guard          = guard,
    with_nack      = with_nack,
    new_cond       = new_cond,
    bracket        = bracket,
    always         = always,
    never          = never,
    Event          = Event,
    -- Event instances have methods: wrap, on_abort, finally, or_else.

    -- higher-level helpers
    race           = race,
    first_ready    = first_ready,
    named_choice   = named_choice,
    boolean_choice = boolean_choice,
}
