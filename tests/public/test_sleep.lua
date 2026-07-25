-- Sleep tests.
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

local fibers = require('fibers')
local Runtime = require('fibers.runtime')
local Sleep = require('fibers.sleep')
local Clock = require('fibers.resource.clock')
local Op = require('fibers.op')

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
    fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag))
  end
end
local function assert_error(fn, msg)
  local ok = pcall(fn)
  if ok then
    fail(msg or 'expected error')
  end
end

-- Sleep is a vocabulary facade; Clock owns observation and relative/absolute
-- time operations.
do
  assert_eq(type(Sleep.sleep_until_op), 'function', 'sleep_until_op export')
  assert_eq(type(Sleep.sleep_op), 'function', 'sleep_op export')
  assert_eq(Sleep.now_op, nil, 'sleep must not expose clock observation')
  assert_eq(Clock.default(), Clock.default(), 'default clock identity is stable')
  assert_eq(type(Clock.default().now_op), 'function', 'clock now_op export')
  assert_eq(type(Clock.default().at_op), 'function', 'clock at_op export')
  assert_eq(type(Clock.default().after_op), 'function', 'clock after_op export')
  assert_eq(type(Clock.default().now), 'function', 'clock direct now export')
  assert_eq(type(Clock.default().at), 'function', 'clock direct at export')
  assert_eq(type(Clock.default().after), 'function', 'clock direct after export')
end

-- Absolute sleep waits until the host clock reaches the deadline.
do
  local now = 0
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local ok, observed
  rt:spawn_raw(function()
    ok, observed = rt:perform(Sleep.sleep_until_op(10))
  end, 'absolute-sleeper')
  local st = rt:run()
  assert_status(st, 'pending')
  now = 10
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(ok, true)
  assert_eq(observed, 10)
end

-- Clock:after_op is the canonical relative-time operation. It elaborates once
-- into an absolute Clock:at_op residual.
do
  local now = 7
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local observed
  rt:spawn_raw(function()
    observed = rt:perform(Clock.default():after_op(3))
  end, 'clock-after')
  assert_status(rt:run(), 'pending')
  now = 10
  assert_status(rt:step(), 'found')
  assert_eq(observed, 10)
end

-- Relative sleep fixes now + delay once for the perform attempt; it does not
-- slide forward when bounded search is rebuilt.
do
  local now = 100
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local ok, observed
  rt:spawn_raw(function()
    ok, observed = rt:perform(Sleep.sleep_op(4))
  end, 'relative-sleeper')
  for _ = 1, 6 do
    rt:step({ max_work = 1 })
  end
  assert_eq(ok, nil, 'sleep should be pending before the fixed deadline')
  now = 104
  for _ = 1, 40 do
    rt:step({ max_work = 1 })
    if ok then
      break
    end
  end
  assert_eq(ok, true, 'relative sleep should commit at the original deadline')
  assert_eq(observed, 104)
end

-- Relative sleep is just option syntax and composes with ordinary choice.
do
  local now = 0
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(
      Sleep.sleep_op(5):map(function()
        return 'slept'
      end),
      Op.always('ready')
    ))
  end, 'sleep-choice')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(got, 'ready')
end

-- Deadlines and delays must be finite numbers.
do
  assert_error(function()
    Sleep.sleep_until_op(0 / 0)
  end, 'NaN deadline should fail')
  assert_error(function()
    Sleep.sleep_until_op(math.huge)
  end, 'infinite deadline should fail')
  assert_error(function()
    Sleep.sleep_op('later')
  end, 'non-number delay should fail')
end

print('tests/test_sleep.lua: ok')
