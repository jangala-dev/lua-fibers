-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

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
local BaseOp = {}
BaseOp.__index = BaseOp

--- Create a new base operation.
-- @tparam function wrap_fn The wrap function.
-- @tparam function try_fn The try function.
-- @tparam function block_fn The block function.
-- @treturn BaseOp The created base operation.
local function new_base_op(wrap_fn, try_fn, block_fn)
    if wrap_fn == nil then wrap_fn = id_wrap end
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

--- CML-style guard: delayed event. g() is evaluated once per
--- synchronization (per call to :perform / :perform_alt, or when used
--- inside a ChoiceOp:perform), and the event it returns participates
--- fully in the choice.
local function guard(g)
    -- A guard is a delayed op. Its try/block are not used directly;
    -- execution always goes through ChoiceOp resolution first.
    local base = new_base_op(
        nil,
        function() return false end,
        function()
            error("guard block_fn should never be called directly")
        end
    )
    base._guard_builder = g
    return base
end
--- Wrap the base operation with the given function.
-- @tparam function f The function.
-- @treturn BaseOp The created base operation.
function BaseOp:wrap(f)
    -- Preserve delayed semantics for guards.
    if self._guard_builder then
        local prev_wrap = self.wrap_fn or id_wrap
        local composed = function(...)
            return f(prev_wrap(...))
        end
        local base = new_base_op(composed, self.try_fn, self.block_fn)
        base._guard_builder = self._guard_builder
        return base
    end
    local wrap_fn, try_fn, block_fn = self.wrap_fn, self.try_fn, self.block_fn
    return new_base_op(function(...) return f(wrap_fn(...)) end, try_fn, block_fn)
end

--- Wrap the choice operation with the given function.
-- @tparam function f The function.
-- @treturn ChoiceOp The created choice operation.
function ChoiceOp:wrap(f)
    local ops = {}
    for _, op in ipairs(self.base_ops) do table.insert(ops, op:wrap(f)) end
    return new_choice_op(ops)
end

local function block_base_op(sched, fib, op)
    op.block_fn(new_suspension(sched, fib), op.wrap_fn)
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

        local guard_wrap = ev.wrap_fn or id_wrap
        local composed_outer = function(...)
            local mid = pack(guard_wrap(...))
            return outer_wrap(unpack(mid, 1, mid.n))
        end

        resolve_event(inner_ev, composed_outer, out)
    else
        -- Plain BaseOp: compose inner wrap under outer_wrap.
        local inner_wrap = ev.wrap_fn or id_wrap
        local composed_wrap = function(...)
            local mid = pack(inner_wrap(...))
            return outer_wrap(unpack(mid, 1, mid.n))
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

-- Treat a delayed event (guard) as a 1-arm choice so guard semantics
-- and choice semantics share the same resolution path.
local function perform_delayed(self)
    return new_choice_op({ self }):perform()
end
--- Perform the base operation.
-- @treturn vararg The value returned by the operation.
function BaseOp:perform()
    -- Delayed events (guards) go through choice resolution.
    if self._guard_builder then
        return perform_delayed(self)
    end
    local retval = pack(self.try_fn())
    local success = table.remove(retval, 1)
    if success then return self.wrap_fn(unpack(retval)) end
    local new_retval = pack(fiber.suspend(block_base_op, self))
    local wrap = table.remove(new_retval, 1)
    return wrap(unpack(new_retval))
end

local function block_choice_op(sched, fib, ops)
    local suspension = new_suspension(sched, fib)
    for _, op in ipairs(ops) do op.block_fn(suspension, op.wrap_fn) end
end

--- Perform the choice operation.
-- @treturn vararg The value returned by the operation.
function ChoiceOp:perform()
    -- Expand guards (and nested choices) once for this synchronization.
    local ops = resolve_choice_ops(self.base_ops)
    local n = #ops
    local base = math.random(n)
    for i = 1, n do
        local op = ops[((i + base) % n) + 1]
        local retval = pack(op.try_fn())
        local success = table.remove(retval, 1)
        if success then return op.wrap_fn(unpack(retval)) end
    end
    local retval = pack(fiber.suspend(block_choice_op, ops))
    local wrap = table.remove(retval, 1)
    return wrap(unpack(retval))
end

--- Perform the base operation or return the result of the function if the operation cannot be performed.
-- @tparam function f The function.
-- @treturn vararg The value returned by the operation or the function.
function BaseOp:perform_alt(f)
    if self._guard_builder then
        return new_choice_op({ self }):perform_alt(f)
    end
    local success, val = self.try_fn()
    if success then return self.wrap_fn(val) end
    return f()
end

--- Perform the choice operation or return the result of the function if the operation cannot be performed.
-- @tparam function f The function.
-- @treturn vararg The value returned by the operation or the function.
function ChoiceOp:perform_alt(f)
    local ops = resolve_choice_ops(self.base_ops)
    local n = #ops
    local base = math.random(n)
    for i = 1, n do
        local op = ops[((i + base) % n) + 1]
        local success, val = op.try_fn()
        if success then return op.wrap_fn(val) end
    end
    return f()
end

return {
    new_base_op = new_base_op,
    choice      = choice,
    guard       = guard,
}
