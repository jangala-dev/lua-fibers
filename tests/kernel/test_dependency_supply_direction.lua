package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Counter = require('fibers.resource.counter')
local Index = require('fibers.resource.index')
local IR = require('fibers.internal.kernel.ir')

local counter = Counter.new(2, 'direction-counter')
local take = counter:take_op(1)
local give = counter:give_op(1)
local take_meta = IR.metadata(take)
local give_meta = IR.metadata(give)
local take_intent = { kind = 'transition', program = take.program }
assert(not IR.metadata_may_supply(take_meta, take_intent))
assert(IR.metadata_may_supply(give_meta, take_intent))

local index = Index.new('direction-index')
local put = index:append_op('value')
local pop = index:pop_first_op()
local put_meta = IR.metadata(put)
local pop_meta = IR.metadata(pop)
local pop_intent = { kind = 'transition', program = pop.program }
local put_intent = { kind = 'transition', program = put.program }
assert(IR.metadata_may_supply(put_meta, pop_intent))
assert(not IR.metadata_may_supply(pop_meta, pop_intent))
assert(IR.metadata_may_supply(pop_meta, put_intent))
assert(not IR.metadata_may_supply(put_meta, put_intent))

local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local machine = Runtime.new().machine_name

local function rejected(fn, fragment)
  local ok, err = pcall(fn)
  assert(not ok, 'expected declaration to be rejected')
  assert(tostring(err):find(fragment, 1, true), 'unexpected error: ' .. tostring(err))
end

-- State-machine transitions have small canonical defaults.
local default_transition = StateMachine.isolated_update(nil, function(value)
  return StateMachine.Ready.write(value + 1, true)
end)
assert(default_transition.accepts_supply == false)
assert(next(default_transition.supplies) == nil)

local query_transition = StateMachine.query(nil, function(value)
  return StateMachine.Ready.same(value)
end)
assert(query_transition.accepts_supply == true)
assert(next(query_transition.supplies) == nil, 'query transitions never supply state')

-- Supplying another transition and accepting supply from siblings are separate
-- declarations.  The producer below refuses sibling supply but can still make
-- the query ready in an interacting product.
local producer = StateMachine.rule('directional-producer', 'update', function(value)
  return StateMachine.Ready.write(value + 1, true)
end, false, 'any')
local observer = StateMachine.query('directional-observer', function(value)
  if value < 1 then
    return StateMachine.Wait
  end
  return StateMachine.Ready.same(value)
end, 100)
local cell = StateMachine.new(0, 'directional-separation')
local rows
local rt = Runtime.new()
rt:spawn_raw(function()
  rows = rt:perform(Op.together({
    cell:transition_op(observer),
    cell:transition_op(producer),
  }))
end, 'directional-separation')
assert(rt:run().tag == 'found')
assert(rows[1][1] == 1)
assert(rows[2][1] == true)
assert(cell.value == 1)

-- Producer metadata records its positive supply direction.
local producer_meta = IR.metadata(cell:transition_op(producer))
local access = assert(producer_meta.locations[cell._location])
assert(access.supplies and access.supplies.any)

local Store = require('fibers.internal.kernel.ledger')
local location = Store.new_location({ name = 'canonical-witness', algebra = 'machine', value = 0 })
rejected(function()
  StateMachine.rule(nil, 'update', function(value)
    return StateMachine.Ready.write(value, true)
  end, true, { any = true, up = true })
end, 'cannot combine any')

-- Read-only dependency queries reuse interned atoms and do not create
-- additional membership records.
local Dependencies = require('fibers.internal.kernel.dependencies')
local dependency_index = Dependencies.Index.new()
local exchange_resource = {}
local put_atom = dependency_index:atom('exchange', exchange_resource, 'put')
local dependency_request = {
  id = 1,
  metadata = {
    exchanges = { [exchange_resource] = { put = true } },
    locations = {},
    resources = {},
  },
}
dependency_index:add(dependency_request)
assert(put_atom:contains(1))
dependency_index:remove(dependency_request)
assert(put_atom.count == 0)
local before_generation = put_atom.generation
dependency_index:each_supplier({
  { kind = 'exchange', resource = exchange_resource, role = 'get' },
}, {}, {}, {}, function() end)
assert(put_atom.generation == before_generation)

-- Dynamic continuations are future dependencies, not active suppliers before
-- their prefix completes. The metadata remains conservatively dynamic for
-- retained-proof eligibility while the dependency index keeps the request out
-- of the opaque global component.
local phase_channel = require('fibers.resource.rendezvous').new('phase-sensitive-and-then')
local phase_op = phase_channel:get_op():and_then(Op.guard(function(value)
  return Op.always(value)
end))
local phase_meta = IR.metadata(phase_op)
assert(phase_meta.dynamic == true)
assert(IR.active_dynamic(phase_meta) == false)
assert(phase_meta.exchanges[phase_channel].get)
local phase_index = Dependencies.Index.new()
local phase_request = { id = 21, op = phase_op, metadata = phase_meta }
phase_index:add(phase_request)
assert(phase_index.opaque.count == 0, 'dormant continuation must not enter opaque bucket')
phase_index:remove(phase_request)

-- A revealed root guard is fixed for the pending activation and may replace its
-- conservative opaque plan with the exact residual plan in the production
-- runtime.
if machine == 'ledger' then
  local guard_channel = require('fibers.resource.rendezvous').new('phase-sensitive-guard')
  local guard_rt = Runtime.new({
    dependency_index_threshold = 1,
    instrumentation = {},
  })
  guard_rt:spawn_raw(function()
    guard_rt:perform(Op.guard(function()
      return guard_channel:get_op()
    end))
  end, 'phase-sensitive-guard')
  local guard_status = guard_rt:run()
  assert(guard_status.tag == 'quiescent')
  local guard_request = assert(guard_rt.pending[1])
  assert(IR.active_dynamic(guard_request.metadata) == false)
  assert(guard_request.metadata.exchanges[guard_channel].get)
  assert(guard_rt:instrumentation_report().counters.dynamic_dependency_refinements >= 1)
end

-- Atoms are interned and use the dense Bucket implementation shared with
-- blocked-domain indexing.
local same_put_atom = dependency_index:atom('exchange', exchange_resource, 'put')
assert(put_atom == same_put_atom, 'dependency atoms must be interned')
assert(put_atom:add(11) and put_atom:add(12) and not put_atom:add(11))
assert(put_atom:remove(11) and put_atom:contains(12) and put_atom.count == 1)

-- A dynamic right-hand guard must recruit dependencies from the residual it
-- actually returns. Fallback cannot commit merely because that dependency was
-- absent from the prefix component before the guard was revealed.
for _, solver in ipairs({ machine }) do
  local sound_rt = Runtime.new({
    machine = solver,
    dependency_index_threshold = 1,
    choice_seed = 1,
  })
  local actual = Cell.new(0, 'dynamic-residual-actual-' .. solver)
  local preferred_result

  sound_rt:spawn_raw(function()
    local preferred = Op.always():and_then(Op.guard(function()
      return actual:expect_op(1):map(function()
        return 'preferred'
      end)
    end))
    preferred_result = sound_rt:perform(preferred:or_else(Op.always('fallback')))
  end, 'dynamic-residual-consumer-' .. solver)

  -- Make the dependency index non-trivial and ensure an actual supplier is
  -- pending in the same arbitration world.
  for i = 1, 4 do
    local unrelated = Cell.new(false, 'dynamic-residual-unrelated-' .. solver .. '-' .. i)
    sound_rt:spawn_raw(function()
      sound_rt:perform(unrelated:expect_op(true))
    end, 'dynamic-residual-unrelated-' .. solver .. '-' .. i)
  end
  sound_rt:spawn_raw(function()
    sound_rt:perform(actual:write_op(1))
  end, 'dynamic-residual-supplier-' .. solver)

  assert(sound_rt:run().tag == 'found')
  assert(preferred_result == 'preferred', 'dynamic residual dependency admitted fallback under ' .. solver)
end

return true
