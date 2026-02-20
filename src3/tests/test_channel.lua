-- tests/test_channel.lua
package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local chan_mod = require 'fibers.channel'
local new_chan = chan_mod.new or (chan_mod.Channel and chan_mod.Channel.new)
assert(type(new_chan) == 'function', 'fibers.channel: no constructor found')

local function assert_getq_empty(ch, msg)
  msg = msg or 'expected get queue to be empty'
  if ch.getq then
    assert(ch.getq.head == nil and ch.getq.tail == nil, msg)
  else
    assert(ch.get_h == nil and ch.get_t == nil, msg)
  end
end

local function assert_putq_empty(ch, msg)
  msg = msg or 'expected put queue to be empty'
  if ch.putq then
    assert(ch.putq.head == nil and ch.putq.tail == nil, msg)
  else
    assert(ch.put_h == nil and ch.put_t == nil, msg)
  end
end

-- basic rendezvous (unbuffered)
do
  local sched = new_sched()
  runtime.init(sched)

  local ch = new_chan()

  local got
  local put_done = false

  runtime.spawn(function()
    got = ch:get()
  end, 'receiver')

  runtime.spawn(function()
    ch:put(123)
    put_done = true
  end, 'sender')

  runtime.main()
  assert(put_done == true)
  assert(got == 123)
end

-- get_op losing in a choice should roll back and unlink itself
do
  local sched = new_sched()
  runtime.init(sched)

  local ch = new_chan()

  runtime.spawn(function()
    local r = op.perform(op.choice(ch:get_op(), op.always('timeout')))
    assert(r == 'timeout')
    assert_getq_empty(ch, 'expected get queue to be empty after rollback')
  end, 'choice-unlink')

  runtime.main()
end

-- buffered: basic FIFO + blocking when full
do
  local sched = new_sched()
  runtime.init(sched)

  local ch = new_chan(2) -- capacity 2

  local got = {}
  local sender_done = false

  runtime.spawn(function()
    ch:put(1)
    ch:put(2)
    ch:put(3) -- should block until a get happens (buffer full)
    sender_done = true
  end, 'buf-sender')

  runtime.spawn(function()
    got[1] = ch:get()
    got[2] = ch:get()
    got[3] = ch:get()
  end, 'buf-receiver')

  runtime.main()

  assert(sender_done == true)
  assert(got[1] == 1 and got[2] == 2 and got[3] == 3, 'buffered FIFO order violated')
  assert_putq_empty(ch, 'expected put queue to be empty at end')
  assert_getq_empty(ch, 'expected get queue to be empty at end')
end

-- buffered: sends should not bypass buffered items (FIFO discipline)
do
  local sched = new_sched()
  runtime.init(sched)

  local ch = new_chan(2)

  local got1, got2
  local done = false

  runtime.spawn(function()
    ch:put('a') -- fills buffer (count=1)
  end, 'buf-fill')

  runtime.spawn(function()
    ch:put('b') -- should enqueue into buffer, not rendezvous past 'a'
  end, 'buf-second')

  runtime.spawn(function()
    got1 = ch:get()
    got2 = ch:get()
    done = true
  end, 'buf-drain')

  runtime.main()

  assert(done == true)
  assert(got1 == 'a' and got2 == 'b', 'buffered FIFO bypassed by rendezvous')
end

-- buffered: nil payload round-trip
do
  local sched = new_sched()
  runtime.init(sched)

  local ch = new_chan(1)

  local got
  local done = false

  runtime.spawn(function()
    ch:put(nil)
  end, 'nil-put')

  runtime.spawn(function()
    got = ch:get()
    done = true
  end, 'nil-get')

  runtime.main()

  assert(done == true)
  assert(got == nil, 'expected nil round-trip in buffered channel')
end

print('test_channel.lua: ok')
