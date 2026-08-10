-- Trusted constructors for identity-bearing internal state.
--
-- This module is intentionally below the public resource surface. Facilities
-- using it may keep raw references in authoritative state, and therefore assume
-- responsibility for never leaking an alias which can violate journal/version
-- semantics.

local Facility = require('fibers.resource.authoring')
local StateResource = require('fibers.internal.state_resource')
local ValueSemantics = require('fibers.internal.value_semantics')

local TrustedState = {}

function TrustedState.cell(value)
  local Cell = require('fibers.resource.cell')
  local cell = Facility.identity(setmetatable({}, Cell), Cell.Kind)
  return StateResource.init(cell, value, 'replace', ValueSemantics.trusted, 'trusted Cell state')
end

function TrustedState.machine(value)
  local Machine = require('fibers.resource.machine')
  local machine = Facility.identity(setmetatable({}, Machine), Machine.Kind)
  return StateResource.init(machine, value, 'machine', ValueSemantics.trusted, 'trusted Machine state')
end

return TrustedState
