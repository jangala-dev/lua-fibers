package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Facility = require('fibers.resource.authoring')
local Operation = require('fibers.internal.operation')
local Runtime = require('fibers.runtime')
local Machine = require('fibers.resource.machine')

local owner = Facility.identity({}, Facility.kind('compact-authoring-test'))
local replace = Facility.location(owner, { algebra = 'replace', value = 0 })
local machine = Facility.location(owner, { algebra = 'machine', value = 0 })

assert(Facility.exchange == nil)
assert(Facility.supply == nil)
assert(Facility.clock_wait == nil)
assert(Facility.is_pack == nil)

-- Inspect derives a read-only, non-serial, single-outcome leaf.
local inspect = Facility.rule.inspect({
  location = replace,
  visibility = 'own',
  demand = 'up',
  step = function(value)
    if value == 0 then return Facility.outcome(nil, value) end
  end,
})
local inspect_rule = Operation.transition_behaviour(inspect)
assert(inspect.mode == nil)
assert(inspect.result == nil)
assert(inspect_rule.serial == false)
assert(inspect_rule.enumerable == false)
assert(inspect_rule.writes == false)
assert(inspect_rule.accepts_supply == false)
assert(next(inspect_rule.supplies) == nil)

-- Change derives write capability, machine seriality and cursor enumeration.
local change = Facility.rule.change({
  location = machine,
  visibility = 'together',
  demand = 'any',
  supply = 'any',
  serial_order = 7,
  cursor = function(value)
    local done = false
    return {
      next = function()
        if done then return nil end
        done = true
        return Facility.outcome(Facility.patch.machine(value + 1), value + 1)
      end,
    }
  end,
})
local change_rule = Operation.transition_behaviour(change)
assert(change.mode == nil)
assert(change.result == nil)
assert(change_rule.serial == true)
assert(change_rule.enumerable == true)
assert(change_rule.writes == true)
assert(change_rule.accepts_supply == true)
assert(change_rule.order == 7)
assert(change_rule.supplies.any == true)

-- Closed façades may retain a private proof-preserving readiness probe.
do
  local machine_resource = Machine.new(0):label('compact-probe')
  local probed = Machine.rule(
    'compact.probe', 'query', function(value)
      if value <= 0 then return Machine.Wait end
      return Machine.Ready.same(value)
    end, 'own', 'none', nil, function(value) return value > 0 end
  )
  machine_resource:transition_op(probed)
  local compiled = assert(machine_resource._transition_specs[probed])
  assert(type(Operation.transition_behaviour(compiled).ready) == 'function')
  assert(probed.mode == nil)
  assert(compiled.name == 'compact.probe')

  local external_resource = {}
  local wake = function() return nil end
  local external = Machine._compile(machine, external_resource, probed, {
    payload = 'payload',
    wake = wake,
  })
  assert(external.name == 'compact.probe')
  assert(external.resource == external_resource)
  assert(external.argument == 'payload')
  assert(external.interest == wake)
end

-- Invalid field combinations are rejected at construction.
local ok, err = pcall(function()
  Facility.rule.inspect({
    location = replace,
    supply = 'up',
    step = function() return Facility.outcome(nil, true) end,
  })
end)
assert(ok == false and tostring(err):find('cannot declare outgoing supply', 1, true))

ok, err = pcall(function()
  Facility.rule.change({
    location = replace,
    step = function() return Facility.outcome(Facility.patch.replace(1), true) end,
  })
end)
assert(ok == false and tostring(err):find('requires an explicit supply', 1, true))

ok, err = pcall(function()
  Facility.rule.inspect({
    location = replace,
    serial_order = 1,
    step = function() return Facility.outcome(nil, true) end,
  })
end)
assert(ok == false and tostring(err):find('only valid for machine locations', 1, true))

-- An inspect rule cannot smuggle a patch through its callback.
do
  local rt = Runtime.new()
  local bad = Facility.rule.inspect({
    location = replace,
    step = function()
      return Facility.outcome(Facility.patch.replace(1), true)
    end,
  })
  rt:spawn_raw(function()
    rt:perform(Facility.op(bad))
  end):label('bad-inspect')
  local ran, run_err = pcall(function() rt:run() end)
  assert(ran == false)
  assert(tostring(run_err):find('inspect rule cannot stage a patch', 1, true))
  assert(replace.value == 0 and replace.version == 0)
end

-- Transition outcomes use one canonical nil-preserving Fibers value pack.
do
  local Values = require('fibers.internal.values')
  local outcome = Facility.outcome(nil, nil, true)
  assert(Values.is(outcome.result))
  assert(outcome.result.n == 2 and outcome.result[1] == nil and outcome.result[2] == true)

  local ok = pcall(function()
    Facility.outcome_packed(nil, { n = 1, true })
  end)
  assert(ok == false)
end

print('tests/test_compact_authoring.lua: ok')
