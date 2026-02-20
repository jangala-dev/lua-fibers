-- tests/test_timer.lua

package.path = '../?.lua;' .. package.path

-- tests/test_timer_unit.lua

local timer = require 'fibers.timer'

local function make_waker()
  return { count = 0, signal = function(self) self.count = self.count + 1 end }
end

do
  local t = timer.new(0)
  local w1, w2 = make_waker(), make_waker()

  local h1 = t:add_absolute(5, w1)
  t:add_absolute(2, w2)

  assert(t:next_entry_time() == 2)

  t:advance(1)
  assert(t.now == 1)
  assert(w1.count == 0 and w2.count == 0)

  t:advance(2)
  assert(t.now == 2)
  assert(w2.count == 1 and w1.count == 0)

  t:cancel(h1)
  assert(t:next_entry_time() == math.huge)

  t:advance(100)
  assert(w1.count == 0)
end

print('test_timer.lua: ok')
