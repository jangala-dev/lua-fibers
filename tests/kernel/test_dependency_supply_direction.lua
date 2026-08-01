package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Counter = require('fibers.resource.counter')
local Index = require('fibers.resource.index')
local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local Rendezvous = require('fibers.resource.rendezvous')
local Operation = require('fibers.internal.operation')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')

local function rejected(fn, fragment)
  local ok, err = pcall(fn)
  assert(not ok, 'expected declaration to be rejected')
  assert(tostring(err):find(fragment, 1, true), 'unexpected error: ' .. tostring(err))
end

-- Conservative static shape may order search, but has no proof authority.
local counter = Counter.new(2, 'direction-counter')
local take, give = counter:take_op(1), counter:give_op(1)
local take_intent = { kind = 'transition', spec = take.spec }
assert(not Operation.may_supply(Operation.shape(take), take_intent))
assert(Operation.may_supply(Operation.shape(give), take_intent))

local index = Index.new('direction-index')
local put, pop = index:append_op('value'), index:pop_first_op()
local pop_intent = { kind = 'transition', spec = pop.spec }
local put_intent = { kind = 'transition', spec = put.spec }
assert(Operation.may_supply(Operation.shape(put), pop_intent))
assert(not Operation.may_supply(Operation.shape(pop), pop_intent))
assert(Operation.may_supply(Operation.shape(pop), put_intent))
assert(not Operation.may_supply(Operation.shape(put), put_intent))

-- Supplying a sibling and accepting sibling supply are separate declarations.
local producer = StateMachine.rule('directional-producer', 'update', function(value)
  return StateMachine.Ready.write(value + 1, true)
end, 'own', 'any')
local observer = StateMachine.query('directional-observer', function(value)
  if value < 1 then return StateMachine.Wait end
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

local producer_meta = Operation.shape(cell:transition_op(producer))
local access = assert(producer_meta.locations[cell._location])
assert(access.supplies and access.supplies.any)

rejected(function()
  StateMachine.rule(nil, 'update', function(value)
    return StateMachine.Ready.write(value, true)
  end, 'together', { any = true, up = true })
end, 'cannot combine any')

-- Dynamic residual dependencies are discovered by execution. A fallback may
-- not commit merely because the dependency was absent from the prefix shape.
do
  local actual = Cell.new(0, 'dynamic-residual-actual')
  local result
  local sound_rt = Runtime.new({ choice_seed = 1 })
  sound_rt:spawn_raw(function()
    local preferred = Op.always():and_then(Op.guard(function()
      return actual:expect_op(1):map(function() return 'preferred' end)
    end))
    result = sound_rt:perform(preferred:or_else(Op.always('fallback')))
  end, 'dynamic-residual-consumer')

  for i = 1, 4 do
    local unrelated = Rendezvous.new('dynamic-residual-unrelated-' .. i)
    sound_rt:spawn_raw(function() sound_rt:perform(unrelated:get_op()) end, 'unrelated-' .. i)
  end
  sound_rt:spawn_raw(function() sound_rt:perform(actual:write_op(1)) end, 'dynamic-residual-supplier')

  assert(sound_rt:run().tag == 'found')
  assert(result == 'preferred', 'execution-derived dependency admitted fallback')
end

return true
