package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A service owner can wait on a service exit and an administrative shutdown in
-- one decision. The losing service wait remains owned; shutdown then requests
-- cancellation and joins the service before the scope exits.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local Signal = require('fibers.resource.signal')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local selected, detail, service_exit

fibers.run(function(scope)
  local jobs = channel.new()
  local shutdown = channel.new()
  local blocked = Signal.new('service-blocked')

  local service = scope:spawn(function()
    while true do
      local job = fibers.perform(Op.choice(jobs:get_op(), blocked:wait_op()))
      if job == 'stop' then
        return 'stopped normally'
      end
    end
  end, 'service')

  scope:spawn(function()
    Sleep.sleep(1)
    shutdown:put('maintenance')
  end, 'operator')

  selected, detail = fibers.perform(Op.named_choice({
    service_exit = service:exit_op(),
    shutdown = shutdown:get_op(),
  }))

  if selected == 'shutdown' then
    service:request_cancel(detail)
    service_exit = fibers.perform(service:exit_op())
  else
    service_exit = detail
  end
end, { host = Host.manual() })

assert(selected == 'shutdown')
assert(detail == 'maintenance')
assert(service_exit.tag == 'cancelled' or service_exit.tag == 'failed')
print('selected:', selected, detail, 'service:', service_exit.tag)
