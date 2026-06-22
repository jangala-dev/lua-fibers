-- Sleep facility tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')
local Runtime = require('fibers.kernel.runtime')
local Sleep = require('fibers.facility.sleep')
local Op = require('fibers.base.op')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag)) end end
local function assert_error(fn, msg)
  local ok = pcall(fn)
  if ok then fail(msg or 'expected error') end
end

-- The facility exports precisely the two option constructors.
do
  assert_eq(type(Sleep.sleep_until_op), 'function', 'sleep_until_op export')
  assert_eq(type(Sleep.sleep_op), 'function', 'sleep_op export')
  assert_eq(type(fibers.sleep_until_op), 'function', 'top-level sleep_until_op export')
  assert_eq(type(fibers.sleep_op), 'function', 'top-level sleep_op export')
end

-- Absolute sleep waits until the host clock reaches the deadline.
do
  local now = 0
  local rt = Runtime.new({ host = { now = function() return now end } })
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

-- Relative sleep fixes now + delay once for the perform attempt; it does not
-- slide forward when bounded search is rebuilt.
do
  local now = 100
  local rt = Runtime.new({ host = { now = function() return now end } })
  local ok, observed
  rt:spawn_raw(function()
    ok, observed = rt:perform(Sleep.sleep_op(4))
  end, 'relative-sleeper')
  for _ = 1, 6 do rt:step({ max_work = 1 }) end
  assert_eq(ok, nil, 'sleep should be pending before the fixed deadline')
  now = 104
  for _ = 1, 40 do
    rt:step({ max_work = 1 })
    if ok then break end
  end
  assert_eq(ok, true, 'relative sleep should commit at the original deadline')
  assert_eq(observed, 104)
end

-- Relative sleep is just option syntax and composes with ordinary choice.
do
  local now = 0
  local rt = Runtime.new({ host = { now = function() return now end } })
  local got
  rt:spawn_raw(function()
    got = rt:perform(Op.choice(
      Sleep.sleep_op(5):map(function() return 'slept' end),
      Op.always('ready')
    ))
  end, 'sleep-choice')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(got, 'ready')
end

-- Deadlines and delays must be finite numbers.
do
  assert_error(function() Sleep.sleep_until_op(0/0) end, 'NaN deadline should fail')
  assert_error(function() Sleep.sleep_until_op(math.huge) end, 'infinite deadline should fail')
  assert_error(function() Sleep.sleep_op('later') end, 'non-number delay should fail')
end

print('tests/test_sleep.lua: ok')
