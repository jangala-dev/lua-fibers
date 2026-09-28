-- fibers/pulse - basic behavioural tests
print('testing: fibers.op')

-- look one level up
package.path = '../src/?.lua;' .. package.path

local fibers  = require "fibers"
local pulse   = require "fibers.pulse"
local mailbox = require "fibers.mailbox"
local sleep   = require "fibers.sleep"

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "assert_eq failed") .. (": got " .. tostring(a) .. ", want " .. tostring(b)), 2)
  end
end

local function assert_true(v, msg)
  if not v then
    error(msg or "assert_true failed", 2)
  end
end

fibers.run(function (_scope)
  local p = pulse.new()
  assert_eq(p:version(), 0, "initial version")

  local tx, rx = mailbox.new(16) -- block policy is fine for a test harness

  --------------------------------------------------------------------------
  -- 1) changed_op blocks and then coalesces to latest version
  --------------------------------------------------------------------------

  fibers.spawn(function ()
    local v, why = fibers.perform(p:changed_op(0))
    assert_true(tx:send({ tag = "w1", v = v, why = why }) == true, "send w1")
  end)

  fibers.spawn(function ()
    local v0 = p:version()
    local v, why = fibers.perform(p:changed_op(v0))
    assert_true(tx:send({ tag = "w2", v = v, why = why }) == true, "send w2")
  end)

  -- Give the waiters a chance to start and block.
  sleep.sleep(0.001)

  -- Signal twice without yielding; waiters should observe the latest snapshot.
  assert_eq(p:signal(), 1, "signal -> 1")
  assert_eq(p:signal(), 2, "signal -> 2")

  local got = {}
  for _ = 1, 2 do
    local r = rx:recv()
    assert_true(r ~= nil, "expected waiter result")
    got[r.tag] = r
  end

  assert_eq(got.w1.v, 2, "w1 coalesces to latest version")
  assert_eq(got.w1.why, nil, "w1 no close reason")
  assert_eq(got.w2.v, 2, "w2 coalesces to latest version")
  assert_eq(got.w2.why, nil, "w2 no close reason")

  --------------------------------------------------------------------------
  -- 2) next_op waits from 'now'
  --------------------------------------------------------------------------

  fibers.spawn(function ()
    local v, why = fibers.perform(p:next_op())
    assert_true(tx:send({ tag = "w3", v = v, why = why }) == true, "send w3")
  end)

  sleep.sleep(0.001)
  assert_eq(p:signal(), 3, "signal -> 3")

  local w3 = rx:recv()
  assert_true(w3 and w3.tag == "w3", "expected w3")
  assert_eq(w3.v, 3, "w3 sees next version")
  assert_eq(w3.why, nil, "w3 no close reason")

  --------------------------------------------------------------------------
  -- 3) close wakes waiters; further signal is ignored; changed_op completes to closed
  --------------------------------------------------------------------------

  fibers.spawn(function ()
    local v, why = fibers.perform(p:next_op())
    assert_true(tx:send({ tag = "w4", v = v, why = why }) == true, "send w4")
  end)

  sleep.sleep(0.001)
  p:close("done")

  local w4 = rx:recv()
  assert_true(w4 and w4.tag == "w4", "expected w4")
  assert_eq(w4.v, nil, "w4 sees closed")
  assert_eq(w4.why, "done", "w4 close reason propagated")

  assert_eq(p:signal(), nil, "signal after close returns nil")

  local v5, why5 = fibers.perform(p:changed_op(p:version()))
  assert_eq(v5, nil, "changed_op after close returns nil")
  assert_eq(why5, "done", "changed_op after close returns close reason")

  tx:close()

  io.write("test_pulse.lua: ok\n")
end)
