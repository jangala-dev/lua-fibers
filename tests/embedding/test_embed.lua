package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local External = require('fibers.embed.external')
local Embed = require('fibers.embed')
local Sleep = require('fibers.sleep')
local fibers = require('fibers')
local Runtime = require('fibers.runtime')

local function eq(actual, expected, message)
  assert(actual == expected, (message or 'values differ') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end

local function advance_until_wait_or_settled(app, limit)
  for _ = 1, limit or 100 do
    local status = app:advance({ max_seconds = 100 })
    if status.state == 'settled' or not status.needs_immediate_resume then return status end
  end
  error('embedded application did not reach a boundary')
end

-- The generic boundary drives time without loading Roblox or a native I/O backend.
do
  local now = 10
  local host = Embed.Queue.new({ now = function() return now end })
  local woke = false
  local app = Embed.Application.new(function()
    fibers.perform(Sleep.sleep_op(2))
    woke = true
  end, { host = host, owns_host = false, max_seconds_per_turn = 100 })

  local status = advance_until_wait_or_settled(app)
  eq(status.state, 'pending')
  eq(status.reason, 'wakeup')
  eq(status.next_deadline, 12)
  assert(not woke)

  now = 12
  status = advance_until_wait_or_settled(app)
  eq(status.state, 'settled')
  assert(app:result().ok and woke)
  app:close()
  host:close()
end

-- External callbacks are queued and delivered only at the next driver boundary.
do
  local host = Embed.Queue.new({ now = function() return 0 end })
  local received
  local feed
  local app = Embed.Application.new(function()
    local runtime = fibers.current_runtime()
    local events
    events, feed = External.events(runtime)
    events:label('embedded-events')
    received = fibers.perform(events:next_op())
  end, { host = host, owns_host = false, max_seconds_per_turn = 100 })

  local status = advance_until_wait_or_settled(app)
  eq(status.state, 'pending')
  assert(feed)
  assert(host:deliver(feed, 'queued'))
  assert(received == nil, 'host callback must not re-enter the runtime')

  status = advance_until_wait_or_settled(app)
  eq(status.state, 'settled')
  eq(received, 'queued')
  app:close()
  host:close()
end


do
  local host = require('fibers.embed.manual').new()
  local ok, err = pcall(require('fibers.embed.application').new, function() end, {
    host = host,
    owns_host = false,
    runtime = {},
  })
  assert(not ok and tostring(err):match('runtime_options'))
  local app = require('fibers.embed.application').new(function()
    require('fibers.perform')(require('fibers.op').never())
  end, { host = host, owns_host = false })
  ok, err = pcall(app.advance, app, { max_steps_per_turn = 1 })
  assert(not ok and tostring(err):match('short per%-call name'))
  local rt = Runtime.new({ host = host })
  ok, err = pcall(External.drive, rt, { host = host, max_driver_iterations = 1 })
  assert(not ok and tostring(err):match('does not accept'))
  app:close()
  host:close()
end

return true
