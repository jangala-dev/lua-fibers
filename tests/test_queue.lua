--- Tests the Queue implementation.
print('testing: fibers.queue')

-- look one level up
package.path = "../?.lua;" .. package.path

local queue = require 'fibers.queue'
local fiber = require 'fibers.fiber'
local helper = require 'fibers.utils.helper'
local equal = helper.equal

local log = {}
local function record(x) table.insert(log, x) end

fiber.spawn(function()
      local q = queue.new()
      record('a');
      q:put('b');
      record('c');
      q:put('d');
      record('e');
      record(q:get())
      q:put('f');
      record('g');
      record(q:get())
      record('h');
      record(q:get())
end)

local function run(...)
   log = {}
   fiber.current_scheduler:run()
   assert(equal(log, { ... }))
end

-- 1. Main fiber runs, creating queue fiber.  It blocks trying to
-- hand off 'b' as the queue fiber hasn't run yet.
run('a')
-- 2. Queue fiber runs, taking 'b', and thereby resuming the main
-- fiber (marking it runnable on the next turn).  Queue fiber blocks
-- trying to get or put.
run()
-- 3. Main fiber runs, is able to put 'd' directly as the queue was
-- waiting on it, then blocks waiting for a 'get'.  Putting 'd'
-- resumed the queue fiber.
run('c', 'e')
-- 4. Queue fiber takes 'd' and is also able to put 'a', resuming the
-- main fiber.
run()
-- 5. Main fiber receives 'b', is able to put 'f' directly, blocks
-- getting from queue.
run('b', 'g')
-- 6. Queue fiber resumed with 'f', puts 'd', then blocks.
run()
-- 7. Main fiber resumed with 'd' and also succeeds getting 'f'.
run('d', 'h', 'f')
-- 8. Queue resumes and blocks.
run()
-- Nothing from here on out.
for i=1,20 do run() end

print('test: ok')
