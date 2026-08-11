local Facility = require('fibers.resource.authoring')
local Direct = require('fibers.internal.direct')
local Contract = require('fibers.internal.contract')

local ClaimSet = {}
ClaimSet.__index = ClaimSet
local Kind = Facility.kind('claim_set')

local function copy_compat(source)
  local out = {}
  for mode, peers in pairs(source or {}) do
    local row = {}
    for peer, allowed in pairs(peers) do row[peer] = allowed end
    out[mode] = row
  end
  return out
end

local copy_map = Contract.copy_table

function ClaimSet.new(compat)
  local claim_set = Facility.identity(setmetatable({ _compat = copy_compat(compat) }, ClaimSet), Kind)
  claim_set._locate = Facility._keyspace(claim_set, {
    algebra = 'finite_map', clone_initial = copy_map,
    put_equal = true, remove_idempotent = true,
  })
  return claim_set
end

local function operations(self, subject)
  local location = self._locate(subject)
  local ops = location._claim_set_operations
  if ops then return ops end
  ops = {
    acquire = Facility.rule.change({
      location = location, resource = self, demand = 'down',
      visibility = 'together', supply = 'up',
      step = function(holders, request)
        local mode, holder = request.mode, request.holder
        for other, held_mode in pairs(holders or {}) do
          if other ~= holder then
            local forward = self._compat[mode] and self._compat[mode][held_mode] == true
            local reverse = self._compat[held_mode] and self._compat[held_mode][mode] == true
            if not (mode == held_mode or forward and reverse) then return nil end
          end
        end
        return Facility.outcome(Facility.patch.map_put(holder, mode, 'overwrite'), true)
      end,
    }),
    release = Facility.rule.change({
      location = location, resource = self, demand = 'up',
      visibility = 'together', supply = 'down',
      step = function(holders, holder)
        if holders[holder] == nil then return nil end
        return Facility.outcome(Facility.patch.map_remove(holder), true)
      end,
    }),
  }
  location._claim_set_operations = ops
  return ops
end

function ClaimSet:acquire_op(subject, mode, holder)
  if subject == nil then error('claim set acquire requires subject', 2) end
  if mode == nil then error('claim set acquire requires mode', 2) end
  if holder == nil then error('claim set acquire requires holder', 2) end
  return Facility.bind(operations(self, subject).acquire, { mode = mode, holder = holder })
end

function ClaimSet:release_op(subject, holder)
  if subject == nil then error('claim set release requires subject', 2) end
  if holder == nil then error('claim set release requires holder', 2) end
  return Facility.bind(operations(self, subject).release, holder)
end

ClaimSet.Kind = Kind
Direct.install(ClaimSet, { 'acquire', 'release' })

return ClaimSet
