-- tests/test_io-wait_fd.lua
package.path = '../?.lua;' .. package.path

local sched_mod  = require 'fibers.sched'
local runtime    = require 'fibers.runtime'
local poller_mod = require 'fibers.io.poller.core'
local wait_fd    = require 'fibers.io.wait_fd'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'

-- Fake clock (not important here, but runtime expects one)
local now = 0
local function now_fn() return now end
local function block_fn(dt) now = now + dt end

local function make_once_backend()
  local delivered = false

  local ops = {
    new_backend = function() return {} end,
    poll = function(_backend, _timeout_ms, rd_set, wr_set)
      if delivered then return nil end

      for fd, _ in pairs(rd_set) do
        delivered = true
        return { [fd] = { rd = true } }
      end
      for fd, _ in pairs(wr_set) do
        delivered = true
        return { [fd] = { wr = true } }
      end
      return nil
    end,
    close_backend = function(_backend) end,
  }

  return poller_mod.new(ops)
end

do
  local sched = sched_mod.new()
  local poller = make_once_backend()
  runtime.init(sched, { now = now_fn, block = block_fn, poller = poller })

  local done = false
  local fd = 42

  runtime.spawn(function()
    op.perform(wait_fd.wait_readable_op(fd))
    done = true
  end, 'wait_fd')

  runtime.main()

  assert(done == true)
  assert(poller.watchers == 0, 'watchers should be zero after commit')
end

do
  -- Abort path: wait_fd should be armed then rolled back (cancelled)
  local sched = sched_mod.new()
  local poller = make_once_backend()
  runtime.init(sched, { now = now_fn, block = block_fn, poller = poller })

  local fd = 43
  local finished = false

  runtime.spawn(function()
    op.perform(op.choice(
      wait_fd.wait_readable_op(fd),
      sleep.sleep_op(0) -- immediate winner
    ))
    finished = true
  end, 'abort_wait_fd')

  runtime.main()

  assert(finished == true)
  assert(poller.watchers == 0, 'watchers should be zero after rollback of losing arm')
end

print('test_io-wait_fd.lua: ok')
