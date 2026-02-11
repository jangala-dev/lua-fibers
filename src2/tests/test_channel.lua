-- tests/test_channel2.lua
package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local chan_mod = require 'fibers.channel'
local new_chan = chan_mod.new or (chan_mod.Channel and chan_mod.Channel.new)
assert(type(new_chan) == 'function', 'fibers.channel: no constructor found')

-- basic rendezvous
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
    assert(ch.get_h == nil and ch.get_t == nil, 'expected get queue to be empty after rollback')
  end, 'choice-unlink')

  runtime.main()
end

print('test_channel.lua: ok')

