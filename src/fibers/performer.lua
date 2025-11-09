-- fibers/performer.lua
---
-- Scope-aware performer.
-- This is the preferred entry point for synchronising on events
-- in normal code. It delegates to the current scope (or the root
-- scope) and uses the raw op.perform under the hood.
--
-- Policies (failure, cancellation, etc.) will be wired into the
-- Scope methods in later stages.
--
-- @module fibers.performer

local scope = require 'fibers.scope'
local op    = require 'fibers.op'

local M = {}

--- Perform an event under the current scope.
-- For now this simply calls the raw op.perform; in later stages
-- Scope:sync can wrap events with policies before performing.
function M.perform(ev)
    -- At this stage, scopes do not transform events, so we just
    -- ensure there *is* a scope and call the raw engine.
    local _ = scope.current()  -- touch to ensure root initialises
    return op.perform(ev)
end

return M
