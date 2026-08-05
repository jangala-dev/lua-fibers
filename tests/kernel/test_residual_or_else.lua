package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Signal = require('fibers.resource.signal')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function status(actual, expected, message)
  eq(actual and actual.tag, expected, message)
end

local pack = table.pack or function(...) return { n = select('#', ...), ... } end
local function one_perform(op, opts)
  local rt, values = Runtime.new(opts or {}), { n = 0 }
  rt:spawn_raw(function() values = pack(rt:perform(op)) end):label('one')
  return rt:run(), values, rt
end

-- Preferred success does not construct the fallback.
do
  local calls = 0
  local st, values = one_perform(Op.always('primary'):or_else(Op.guard(function()
    calls = calls + 1
    return Op.always('fallback')
  end)))
  status(st, 'found')
  eq(values[1], 'primary')
  eq(calls, 0)
end

-- Exact local absence opens the fallback once.
do
  local calls = 0
  local st, values = one_perform(Op.never():or_else(Op.guard(function()
    calls = calls + 1
    return Op.always('fallback')
  end)))
  status(st, 'found')
  eq(values[1], 'fallback')
  eq(calls, 1)
end

-- A waitable but presently unsupported preferred branch permits fallback.
do
  local event = Signal.new():label('residual-unready')
  local st, values = one_perform(event:wait_op():or_else(Op.always('fallback')))
  status(st, 'found')
  eq(values[1], 'fallback')
end

-- If the fallback is also absent, discarded preferred waits do not survive.
do
  local event = Signal.new():label('residual-unready-never')
  local st = one_perform(event:wait_op():or_else(Op.never()), { quiet_deadlock = true })
  status(st, 'quiescent')
end

-- A visible rendezvous partner keeps the preferred world ahead of fallback.
do
  local channel, rt = Rendezvous.new():label('residual-primary'), Runtime.new()
  local got, sent
  rt:spawn_raw(function() got = rt:perform(channel:get_op():or_else(Op.always('fallback'))) end):label('receiver')
  rt:spawn_raw(function() sent = rt:perform(channel:put_op('payload')) end):label('sender')
  status(rt:run(), 'found')
  eq(got, 'payload')
  eq(sent, true)
end

-- Partner backtracking may reveal the preferred world.
do
  local wanted, dead = Rendezvous.new():label('residual-wanted'), Rendezvous.new():label('residual-dead')
  local rt, receiver, partner = Runtime.new(), nil, nil
  rt:spawn_raw(function()
    receiver = rt:perform(wanted:get_op():map(function(v) return 'primary:' .. v end):or_else(Op.always('fallback')))
  end):label('receiver')
  rt:spawn_raw(function() partner = rt:perform(Op.choice(dead:put_op('dead'), wanted:put_op('ok'))) end):label('partner')
  status(rt:run(), 'found')
  eq(receiver, 'primary:ok')
  eq(partner, true)
end

-- Bounded proof retains the same semantics both without and with a late focus.
do
  local rt, got = Runtime.new(), nil
  rt:spawn_raw(function()
    got = rt:perform(Rendezvous.new():label('cursor-residual-no-sender'):get_op():or_else(Op.always('fallback')))
  end):label('cursor-residual')
  local st
  for _ = 1, 80 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then break end
  end
  status(st, 'found')
  eq(got, 'fallback')
end

do
  local channel, rt = Rendezvous.new():label('cursor-residual-with-sender'), Runtime.new()
  local got, sent
  rt:spawn_raw(function() got = rt:perform(channel:get_op():or_else(Op.always('fallback'))) end):label('receiver')
  rt:spawn_raw(function() sent = rt:perform(channel:put_op('payload')) end):label('sender')
  local st
  for _ = 1, 120 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then break end
  end
  status(st, 'found')
  eq(got, 'payload')
  eq(sent, true)
end

print('tests/kernel/test_residual_or_else.lua: ok')
