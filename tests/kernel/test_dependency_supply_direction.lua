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

local counter = Counter.new({ initial = 2, min = 0 }, 'direction-counter')
local take = counter:take_op(1)
local give = counter:give_op(1)
local take_meta = IR.metadata(take)
local give_meta = IR.metadata(give)
local take_intent = { kind = 'claim', program = take.program }
assert(not IR.metadata_may_supply(take_meta, take_intent))
assert(IR.metadata_may_supply(give_meta, take_intent))

local index = Index.new({}, 'direction-index')
local put = index:append_op('value')
local pop = index:pop_first_op()
local put_meta = IR.metadata(put)
local pop_meta = IR.metadata(pop)
local pop_intent = { kind = 'claim', program = pop.program }
local put_intent = { kind = 'claim', program = put.program }
assert(IR.metadata_may_supply(put_meta, pop_intent))
assert(not IR.metadata_may_supply(pop_meta, pop_intent))
assert(IR.metadata_may_supply(pop_meta, put_intent))
assert(not IR.metadata_may_supply(put_meta, put_intent))

local Scalar = require('fibers.scalar')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')

local function rejected(fn, fragment)
  local ok, err = pcall(fn)
  assert(not ok, 'expected declaration to be rejected')
  assert(tostring(err):find(fragment, 1, true), 'unexpected error: ' .. tostring(err))
end

-- Trusted state-machine transitions must use the one canonical protocol.
rejected(function()
  Scalar.transition({
    mode = 'update',
    accepts_supply = true,
    step = function(value)
      return value + 1, true
    end,
  })
end, 'requires an explicit supplies declaration')

rejected(function()
  Scalar.transition({
    mode = 'update',
    supply = 'interacting',
    accepts_supply = true,
    supplies = 'any',
    step = function(value)
      return value + 1, true
    end,
  })
end, 'no longer accepts supply')

rejected(function()
  Scalar.transition({
    mode = 'query',
    accepts_supply = true,
    supplies = 'any',
    step = function(value)
      return Scalar.Ready.same(value)
    end,
  })
end, 'query transitions cannot declare supplied state')

-- Supplying another transition and accepting supply from siblings are separate
-- declarations.  The producer below refuses sibling supply but can still make
-- the query ready in an interacting product.
local producer = Scalar.transition({
  name = 'directional-producer',
  mode = 'update',
  accepts_supply = false,
  supplies = 'any',
  order = 0,
  step = function(value)
    return value + 1, true
  end,
})
local observer = Scalar.transition({
  name = 'directional-observer',
  mode = 'query',
  accepts_supply = true,
  supplies = 'none',
  order = 100,
  step = function(value)
    if value < 1 then
      return Scalar.Wait
    end
    return Scalar.Ready.same(value)
  end,
})
local scalar = Scalar.new(0, 'directional-separation')
local rows
local rt = Runtime.new()
rt:spawn_raw(function()
  rows = rt:perform(Op.tensor({
    scalar:transition_op(observer),
    scalar:transition_op(producer),
  }))
end, 'directional-separation')
assert(rt:run().tag == 'found')
assert(rows[1][1] == 1)
assert(rows[2][1] == true)
assert(scalar.value == 1)

-- Canonical metadata contains only the supply set, never compatibility fields.
local producer_meta = IR.metadata(scalar:transition_op(producer))
local access = assert(producer_meta.locations[scalar._location])
assert(access.supplies and access.supplies.any)
assert(access.supply == nil)
assert(access.supply_up == nil)
assert(access.supply_down == nil)
assert(access.supply_any == nil)

local Store = require('fibers.internal.kernel.store')
local location = Store.new_location({ name = 'canonical-witness', merge = 'machine', value = 0 })
rejected(function()
  IR.witness_transition({
    location = location,
    supplies = 'any',
    cursor = function()
      return {
        next = function()
          return nil
        end,
      }
    end,
  })
end, 'requires accepts_supply')

rejected(function()
  IR.witness_transition({
    location = location,
    supply = 'interacting',
    accepts_supply = true,
    supplies = 'any',
    cursor = function()
      return {
        next = function()
          return nil
        end,
      }
    end,
  })
end, 'no longer accepts supply')

rejected(function()
  Scalar.transition({
    mode = 'update',
    accepts_supply = true,
    supplies = { any = true, up = true },
    step = function(value)
      return value, true
    end,
  })
end, 'cannot combine any')

local declared_any = IR.metadata_hint({
  locations = {
    [counter._location] = {
      read = true,
      write = true,
      supplies = 'any',
    },
  },
})
assert(IR.metadata_covers(declared_any, give_meta))

local declared_up = IR.metadata_hint({
  locations = {
    [counter._location] = {
      read = true,
      write = true,
      supplies = 'up',
    },
  },
})
local arbitrary_write = IR.metadata(Scalar.new(0, 'arbitrary-write'):write_op(1))
local covers_arbitrary = IR.metadata_covers(declared_up, arbitrary_write)
assert(not covers_arbitrary, 'directional declaration must not cover explicit any supply')

return true
