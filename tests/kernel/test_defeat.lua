-- Typed defeat consequences replace event-shaped negative acknowledgements.
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Effect = require('fibers.effect')
local Runtime = require('fibers.runtime')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

local fired = {}
local DefeatKind
DefeatKind = Effect.kind({
  name = 'test-defeat',
  key = function(payload)
    return payload.id
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = DefeatKind,
      key = payload.id,
      payload = payload,
      discharge = function(_runtime, entry)
        fired[#fired + 1] = entry.payload.id
      end,
    }
  end,
})

local function defeat(id)
  return Effect.of(DefeatKind, { id = id })
end

-- A losing competing occurrence dispatches its typed obligation once.
do
  fired = {}
  local got
  local rt = Runtime.new({ choice_seed = 2 })
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(Op.always('winner'), Op.always('loser'):on_defeat(defeat('loser'))))
  end, 'defeat-loser')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(table.concat(fired, ','), 'loser')
end

-- Selection discards the annotation rather than dispatching it.
do
  fired = {}
  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(Op.always('selected'):on_defeat(defeat('selected')), Op.never()))
  end, 'defeat-selected')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'selected')
  assert_eq(#fired, 0)
end

-- Certified retry and residual fallback are not defeat.
do
  fired = {}
  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    got = rt:perform(Op.never():on_defeat(defeat('retry')):or_else(Op.always('fallback')))
  end, 'defeat-retry')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(#fired, 0)
end

-- If no world commits there is no terminal defeat decision.
do
  fired = {}
  local rt = Runtime.new({ quiet_deadlock = true })
  rt:spawn_raw(function()
    rt:perform(Op.choice(Op.never():on_defeat(defeat('left')), Op.never():on_defeat(defeat('right'))))
  end, 'defeat-no-commit')
  assert_status(rt:run(), 'quiescent')
  assert_eq(#fired, 0)
end

-- Product lanes are jointly entered, so their annotations retire when the
-- whole product loses an enclosing competition.
do
  fired = {}
  local got
  local rt = Runtime.new({ choice_seed = 2 })
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(
      Op.always('winner'),
      Op.each({
        Op.always('a'):on_defeat(defeat('lane-a')),
        Op.always('b'):on_defeat(defeat('lane-b')),
      })
    ))
  end, 'defeat-product')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  table.sort(fired)
  assert_eq(table.concat(fired, ','), 'lane-a,lane-b')
end

print('tests/test_defeat.lua: ok')
