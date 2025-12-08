-- Introduce multiple fibers and time-based suspension.
--
-- fibers.spawn(fn, ...) attaches a new fiber to the current scope and
-- returns immediately.
-- sleep(dt) yields the current fiber for approximately dt seconds; other
-- fibers continue to run.
-- When all fibers in the root scope complete, the scheduler stops and
-- run(main) returns.

package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local run    = fibers.run
local spawn  = fibers.spawn

local sleep  = require 'fibers.sleep'.sleep

local function worker(name, delay, count)
  for i = 1, count do
    print(("[%s] tick %d"):format(name, i))
    sleep(delay)
  end
  print(("[%s] done"):format(name))
end

local function main()
  -- Spawn three child fibers under the current scope.
  spawn(worker, "fast",  0.2, 5)
  spawn(worker, "medium", 0.5, 4)
  spawn(worker, "slow",  1.0, 3)

  -- Unlike Go our main fiber will wait for its scope to finish.
  -- Once all children complete, scope reaches status "ok"
  -- and fibers.run() returns.
  print("Main fiber returning; children will keep the scheduler busy")
end

run(main)
