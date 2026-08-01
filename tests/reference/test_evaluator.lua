package.path = table.concat({ './?.lua', './?/init.lua', './?/?/init.lua', package.path }, ';')

local Ref = require('reference.evaluator')
local Op = Ref.Op

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assertion failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function one(result)
  eq(result.tag, 'Hit')
  eq(#result.worlds, 1)
  return result.worlds[1]
end

-- Choice denotes all admissible alternatives; source order is not preference.
do
  local result = Ref.evaluate(Op.choice(Op.always('a'), Op.always('b')))
  eq(result.tag, 'Hit')
  eq(#result.worlds, 2)
end

-- A failed transactional prefix is retracted before certified fallback begins.
do
  local preferred = Op.set('mode', 'new'):and_then(Op.never())
  local world = one(Ref.evaluate(preferred:or_else(Op.read('mode')), {
    locations = { mode = Ref.replace_location('old') },
  }))
  eq(world.result[1], 'old')
  eq(world.locations.mode, 'old')
end

-- Independent siblings cannot positively supply one another.
do
  local result = Ref.evaluate(Op.each(Op.add('stock', 1), Op.take('stock', 1)), {
    locations = { stock = Ref.add_location(0) },
  })
  eq(result.tag, 'Retry')
end

-- Interacting siblings may supply one another in the same world.
do
  local world = one(Ref.evaluate(Op.together(Op.add('stock', 1), Op.take('stock', 1)), {
    locations = { stock = Ref.add_location(0) },
  }))
  eq(world.locations.stock, 0)
  eq(world.result[1][1][1], true)
  eq(world.result[1][2][1], true)
end

-- The same distinction applies to rendezvous.
do
  local blocked = Ref.evaluate(Op.each(Op.put('gate', 'value'), Op.get('gate')))
  eq(blocked.tag, 'Retry')

  local world = one(Ref.evaluate(Op.together(Op.put('gate', 'value'), Op.get('gate'))))
  eq(world.result[1][1][1], true)
  eq(world.result[1][2][1], 'value')
end

-- Preferred worlds suppress fallback; fallback is used only after Retry.
do
  local preferred = Op.take('stock', 1):or_else(Op.always('fallback'))
  local hit = one(Ref.evaluate(preferred, { locations = { stock = 1 } }))
  eq(hit.result[1], true)
  eq(hit.locations.stock, 0)

  local fallback = one(Ref.evaluate(preferred, { locations = { stock = 0 } }))
  eq(fallback.result[1], 'fallback')
  eq(fallback.locations.stock, 0)
end

-- and_then plus guard carries provisional values without committing the prefix.
do
  local op = Op.read('stock'):and_then(Op.guard(function(value)
    return Op.take('stock', value)
  end))
  local world = one(Ref.evaluate(op, { locations = { stock = 3 } }))
  eq(world.result[1], true)
  eq(world.locations.stock, 0)
end

-- Conflicting replacement writes reject the complete product.
do
  local result = Ref.evaluate(Op.each(Op.set('mode', 'a'), Op.set('mode', 'b')), {
    locations = { mode = 'old' },
  })
  eq(result.tag, 'Retry')
end

-- Effects are inert obligations selected with the world.
do
  local result = Ref.evaluate(Op.choice(
    Op.emit('left'):and_then(Op.always('left')),
    Op.emit('right'):and_then(Op.always('right'))
  ))
  eq(result.tag, 'Hit')
  eq(#result.worlds, 2)
  local seen = {}
  for i = 1, #result.worlds do
    local world = result.worlds[i]
    seen[world.result[1]] = world.effects[1]
  end
  eq(seen.left, 'left')
  eq(seen.right, 'right')
end

-- A search boundary is Unknown, never Retry.
do
  local op = Op.always('end')
  for i = 1, 12 do op = Op.choice(op, Op.always(i)) end
  local result = Ref.evaluate(op, { max_steps = 2 })
  eq(result.tag, 'Unknown')
end

print('tests/reference/test_evaluator.lua: ok')
