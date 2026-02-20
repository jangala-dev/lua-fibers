-- tests/test_sleep.lua
package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local runtime   = require 'fibers.runtime'
local sleep     = require 'fibers.sleep'

local now = 0
local function now_fn() return now end
local function block_fn(dt) now = now + dt end

do
  local sched = sched_mod.new()
  runtime.init(sched, { now = now_fn, block = block_fn, maxsleep = 10 })

  local started, finished = nil, nil

  runtime.spawn(function()
    started = runtime.now()
    sleep.sleep(0.5)
    finished = runtime.now()
  end, 'sleepy')

  runtime.main()

  assert(started ~= nil and finished ~= nil)
  assert(finished - started >= 0.5, 'sleep did not advance time by at least dt')
end

print('test_sleep.lua: ok')
