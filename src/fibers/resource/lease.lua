local Facility = require('fibers.resource.authoring')
local Keyspace = require('fibers.resource.keyspace')
local Direct = require('fibers.internal.direct')
local Contract = require('fibers.internal.contract')

local Lease = {}
Lease.__index = Lease
local Kind = Facility.kind('lease')

local function copy_compat(source)
  local out = {}
  for mode, peers in pairs(source or { lease = {} }) do
    local row = {}
    for peer, allowed in pairs(peers) do row[peer] = allowed end
    out[mode] = row
  end
  return out
end

local copy_map = Contract.copy_table

function Lease.new(compat)
  local lease = Facility.identity(setmetatable({ _compat = copy_compat(compat) }, Lease), Kind)
  lease._space = Keyspace.new(lease, {
    algebra = 'finite_map', domain = 'finite_map', clone_initial = copy_map,
    put_equal = true, remove_idempotent = true,
  })
  return lease
end

local function operations(self, subject)
  local location = self._space:location(subject)
  local ops = location._lease_operations
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
  location._lease_operations = ops
  return ops
end

function Lease:acquire_op(subject, mode, holder)
  if subject == nil then error('lease acquire requires subject', 2) end
  if mode == nil then error('lease acquire requires mode', 2) end
  if holder == nil then error('lease acquire requires holder', 2) end
  return Facility.bind(operations(self, subject).acquire, { mode = mode, holder = holder })
end

function Lease:release_op(subject, holder)
  if subject == nil then error('lease release requires subject', 2) end
  if holder == nil then error('lease release requires holder', 2) end
  return Facility.bind(operations(self, subject).release, holder)
end

Lease.Kind = Kind
Direct.install(Lease, { 'acquire', 'release' })

return Lease
