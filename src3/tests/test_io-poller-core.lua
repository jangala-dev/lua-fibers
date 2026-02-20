-- tests/test_io-poller-core.lua
package.path = '../?.lua;' .. package.path

local poller_mod = require 'fibers.io.poller.core'

local function make_waker()
  return { count = 0, signal = function(self) self.count = self.count + 1 end }
end

local next_events = nil
local ops = {
  new_backend = function() return {} end,
  poll = function(_backend, _timeout_ms, _rd_set, _wr_set)
    local ev = next_events
    next_events = nil
    return ev
  end,
  close_backend = function(_backend) end,
}

local p = poller_mod.new(ops)

do
  local w1, w2 = make_waker(), make_waker()

  local n1 = p:watch(10, 'rd', w1)
  local n2 = p:watch(10, 'rd', w2)

  assert(p.watchers == 2)
  assert(p.rd_cnt[10] == 2)
  assert(p.rd_set[10] == true)

  next_events = { [10] = { rd = true } }
  p:poll(0)

  assert(n1.fired == true and n2.fired == true)
  assert(w1.count == 1 and w2.count == 1)

  p:cancel(n1)
  assert(p.watchers == 1)
  assert(p.rd_cnt[10] == 1)
  assert(p.rd_set[10] == true)

  p:cancel(n2)
  assert(p.watchers == 0)
  assert(p.rd_cnt[10] == nil)
  assert(p.rd_set[10] == nil)
  assert(p.rd[10] == nil)

  -- idempotent cancel should not underflow
  p:cancel(n2)
  assert(p.watchers == 0)
end

print('test_io-poller-core.lua: ok')
