package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local channel = require('fibers.channel')

local function direct_version()
  local jobs = channel.new()
  local replies = channel.new()
  local outcome

  fibers.run(function()
    fibers.spawn(function()
      local job = jobs:get()
      replies:put('completed ' .. job)
    end, 'direct-worker')

    jobs:put('inspection')
    outcome = replies:get()
  end)

  return outcome
end

local function composed_version()
  local jobs = channel.new()
  local replies = channel.new()
  local stop = channel.new()
  local outcome

  fibers.run(function()
    fibers.spawn(function()
      fibers.perform(jobs:get_op():and_then(function(job)
        return replies:put_op('completed ' .. job)
      end))
    end, 'composed-worker')

    local completed = jobs:put_op('inspection')
      :and_then(function()
        return replies:get_op()
      end)
      :map(function(reply)
        return 'worker: ' .. reply
      end)

    local stopped = stop:get_op():map(function(reason)
      return 'stopped: ' .. reason
    end)

    outcome = fibers.perform(fibers.choice(completed, stopped))
  end)

  return outcome
end

assert(direct_version() == 'completed inspection')
assert(composed_version() == 'worker: completed inspection')

print('examples/tutorial/00_getting_started.lua: ok')
