--- A Lua context library for managing hierarchies of fibers with
--- cancellation, deadlines, and values.
--- This version follows Go's context pattern more closely:
---   - Only "cancel contexts" (from with_cancel, with_deadline,
---     with_timeout) can independently cause cancellation.
---   - Value contexts do not spawn their own cancellation paths;
---     they simply hold extra keys and defer cancellation to their parent.
--- Each context is one of:
---   - base_context: The root logic for value lookup and deferring .err()
---     and .done_op() to a parent.
---   - cancel_context: Extends base_context with a local cause, waitgroup,
---     and a .cancel() method that propagates to children.
---   - value_context: Extends base_context with a local key/value, no local
---     cancellation.
-- @module context

local fiber          = require "fibers.fiber"
local waitgroup      = require "fibers.waitgroup"
local op             = require "fibers.op"
local sleep          = require "fibers.sleep"

-- ------------------------------------------------------------------------
-- base_context:
-- A minimal context that defers cancellation, deadlines, and values to its
-- parent. background() returns a base_context with no parent.
-- ------------------------------------------------------------------------
local base_context   = {}
base_context.__index = base_context

--- Create a new base_context with the specified parent.
--- Typically used internally by derived contexts (cancel_context,
--- value_context).
-- @param parent The parent context.
-- @return A new base_context.
function base_context:new(parent)
    local ctx = setmetatable({ parent = parent, children = {} }, self)
    if parent then table.insert(parent.children, ctx) end
    return ctx
end

--- Returns a new operation that completes when this context is done.
--- For a plain base_context with no parent, we are never cancelled,
--- so an op that is immediately satisfied is returned.
-- @return An op representing the done state.
function base_context:done_op()
    return self.parent and self.parent:done_op() or op.new_base_op(nil, function() return true end, nil)
end

--- Returns any cancellation cause if known.
--- If none exists, defers to the parent.
-- @return The cancellation cause or nil.
function base_context:err()
    return self.parent and self.parent:err() or nil
end

--- Lookup a value in this context.
--- By default, the lookup defers to the parent.
-- @param key The key to look up.
-- @return The associated value, or nil.
function base_context:value(key)
    return self.parent and self.parent:value(key) or nil
end

-- ------------------------------------------------------------------------
-- cancel_context:
-- A context that can be cancelled on its own, or via its parent.
-- It has a local cause, a waitgroup for done_op, and a .cancel() method.
-- ------------------------------------------------------------------------
local cancel_context = setmetatable({}, { __index = base_context })
cancel_context.__index = cancel_context

--- Create a new cancel_context with the specified parent.
--- This arranges for the child's cancellation if the parent is cancelled.
-- @param parent The parent context.
-- @return A new cancel_context.
function cancel_context:new(parent)
    local base = base_context.new(self, parent)
    base.wg = waitgroup.new()
    base.wg:add(1)   -- done_op completes when cancel() is called
    base.cause = nil -- local cause for cancellation
    if parent then
        fiber.spawn(function()
            parent:done_op():perform()
            local parent_cause = parent:err()
            if parent_cause then base:cancel(parent_cause) end
        end)
    end
    return base
end

--- Cancel this context with an optional cause.
--- If no cause is provided, "canceled" is used.
-- @param cause The cancellation reason.
function cancel_context:cancel(cause)
    if self.cause then return end
    self.cause = cause or "canceled"
    self.wg:done()
    for _, child in ipairs(self.children) do
        if child.cancel then child:cancel(cause) end
    end
end

--- Overridden err() that includes a local cause check.
-- @return The cancellation cause.
function cancel_context:err()
    return self.cause or base_context.err(self)
end

--- Returns the done operation for this cancel_context.
-- @return An op representing the done state.
function cancel_context:done_op()
    return self.wg:wait_op()
end

-- ------------------------------------------------------------------------
-- value_context:
-- A simple context that stores one additional key/value pair but relies on
-- the parent for cancellation.
-- ------------------------------------------------------------------------
local value_context = setmetatable({}, { __index = base_context })
value_context.__index = value_context

--- Create a new value_context with the specified parent, key, and value.
-- @param parent The parent context.
-- @param key The key for the value.
-- @param val The value to store.
-- @return A new value_context.
function value_context:new(parent, key, val)
    local ctx = base_context.new(self, parent)
    ctx.key, ctx.val = key, val
    return ctx
end

--- Lookup a value in this context.
--- If the key matches this context's key, its value is returned;
--- otherwise, the lookup defers to the parent.
-- @param k The key to look up.
-- @return The associated value, or nil.
function value_context:value(k)
    return k == self.key and self.val or base_context.value(self, k)
end

-- ------------------------------------------------------------------------
-- Top-level functions for external use.
-- ------------------------------------------------------------------------

--- The root context that is never cancelled and holds no values.
-- @return A new background context.
local function background()
    return setmetatable({ parent = nil, children = {} }, base_context)
end

--- Returns a child cancel_context and a cancellation function.
-- @param parent The parent context.
-- @return The new cancel_context and a function to cancel it.
local function with_cancel(parent)
    local ctx = cancel_context:new(parent)
    return ctx, function(cause) ctx:cancel(cause) end
end

--- Returns a cancel_context that is automatically cancelled when the
--- specified deadline is reached.
-- @param parent The parent context.
-- @param deadline The deadline time.
-- @return The new cancel_context and a cancellation function.
local function with_deadline(parent, deadline)
    local ctx, cancel_fn = with_cancel(parent)
    fiber.spawn(function()
        if deadline > fiber.now() then sleep.sleep_until(deadline) end
        ctx:cancel("deadline_exceeded")
    end)
    return ctx, cancel_fn
end

--- Returns a cancel_context that is automatically cancelled after
--- timeout seconds.
-- @param parent The parent context.
-- @param timeout The timeout in seconds.
-- @return The new cancel_context and a cancellation function.
local function with_timeout(parent, timeout)
    return with_deadline(parent, fiber.now() + timeout)
end

--- Returns a value_context that stores a key/value pair.
--- It defers all cancellation to the parent.
-- @param parent The parent context.
-- @param key The key to store.
-- @param val The value to store.
-- @return A new value_context.
local function with_value(parent, key, val)
    return value_context:new(parent, key, val)
end

return {
    background    = background,
    with_cancel   = with_cancel,
    with_deadline = with_deadline,
    with_timeout  = with_timeout,
    with_value    = with_value
}
