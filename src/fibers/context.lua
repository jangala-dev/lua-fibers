--- A Lua context library for managing hierarchies of fibers with
--- cancellation, deadlines, and values.
--- This version more closely follows Go's context pattern:
---   - Only cancellation contexts (from with_cancel, with_deadline,
---     with_timeout) trigger cancellation.
---   - Value contexts merely hold extra keys and defer cancellation to their parent.
--- Each context is one of:
---   - base_context: The root logic for value lookup and for deferring .err()
---     and .done_op() to a parent.
---   - cancel_context: Extends base_context with a local cancellation cause and
---     a condition variable for signalling cancellation.
---   - value_context: Extends base_context with a local key/value, with no local
---     cancellation.
-- @module context

local runtime          = require "fibers.runtime"
local op             = require "fibers.op"
local cond           = require "fibers.cond"

local perform = require 'fibers.performer'.perform

-- ------------------------------------------------------------------------
-- base_context:
-- Minimal context that defers cancellation, deadlines and values to its parent.
-- background() returns a base_context with no parent.
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

--- Returns an op that completes when this context is done.
--- For a background context (no parent), the op never completes.
function base_context:done_op()
    if self.parent then
        return self.parent:done_op()
    else
        -- Background context: never cancelled, so done_op never completes.
        return op.new_primitive(nil, function() return false end, function() end)
    end
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
-- A context that can be cancelled locally or via its parent.
-- It uses a condition variable to signal cancellation.
-- ------------------------------------------------------------------------
local cancel_context = {}
cancel_context.__index = cancel_context
setmetatable(cancel_context, { __index = base_context })

--- Create a new cancel_context with the specified parent.
--- This arranges for the child's cancellation if the parent is cancelled.
-- @param parent The parent context.
-- @return A new cancel_context.
function cancel_context:new(parent)
    local base = base_context.new(self, parent)
    base.cond = cond.new() -- condition variable for signalling cancellation
    base.cause = nil       -- local cancellation cause
    return base
end

--- Cancel this context with an optional cause.
--- If no cause is provided, "canceled" is used.
-- @param cause The cancellation reason.
function cancel_context:cancel(cause)
    if self.cause then return end
    self.cause = cause or "canceled"
    self.cond:signal() -- signal cancellation to waiters
    for _, child in ipairs(self.children) do
        if child.cancel then child:cancel(cause) end
    end
end

--- Returns an op that completes when this context is cancelled.
--- This op is a choice between the parent's done op and the local cond wait op.
function cancel_context:done_op()
    local local_op = self.cond:wait_op()
    if self.parent then
        return op.choice(self.parent:done_op(), local_op)
    else
        return local_op
    end
end

function cancel_context:done()
    return perform(self:done_op())
end

--- Overridden err() that checks for a local cancellation cause.
function cancel_context:err()
    return self.cause or (self.parent and self.parent:err() or nil)
end

-- ------------------------------------------------------------------------
-- value_context:
-- A simple context that stores one additional key/value pair.
-- It defers all cancellation to the parent.
-- ------------------------------------------------------------------------
local value_context = {}
value_context.__index = value_context
setmetatable(value_context, { __index = base_context })

--- Create a new value_context with the specified parent, key and value.
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
-- @param The parent context.
-- @return The new cancel_context and a function to cancel it.
local function with_cancel(parent)
    local ctx = cancel_context:new(parent)
    return ctx, function(cause) ctx:cancel(cause) end
end

--- Returns a cancel_context that is automatically cancelled when the specified deadline is reached.
-- @param The parent context.
-- @param The deadline at which the context will be cancelled.
-- @return The new with_deadline_context and a function to cancel it.
local function with_deadline(parent, deadline)
    local ctx, cancel_fn = with_cancel(parent)
    runtime.current_scheduler:schedule_at_time(deadline, { run = function() ctx:cancel("deadline_exceeded") end })
    return ctx, cancel_fn
end

--- Returns a cancel_context that is automatically cancelled after timeout seconds.
-- @param The parent context.
-- @param The timeout at which the context will be cancelled.
-- @return The new with_timeout_context and a function to cancel it.
local function with_timeout(parent, timeout)
    return with_deadline(parent, runtime.now() + timeout)
end

--- Returns a value_context that stores a key/value pair.
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
