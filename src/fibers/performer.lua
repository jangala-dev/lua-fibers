-- fibers/performer.lua
---
-- Scope-aware performer.
-- Preferred entry point for synchronising on events in normal code.
-- Delegates to the current scope if available, otherwise falls back
-- to the raw op.perform.
--
-- @module fibers.performer

local op = require 'fibers.op'

local scope_mod

local M = {}

local function current_scope()
    if not scope_mod then
        scope_mod = require 'fibers.scope'
    end
    return scope_mod.current and scope_mod.current() or nil
end

function M.perform(ev)
    local s = current_scope()
    if s and s.sync then
        return s:sync(ev)
    else
        return op.perform_raw(ev)
    end
end

return M
