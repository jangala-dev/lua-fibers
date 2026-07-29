package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- An operations centre can wait on dispatch-engine exit and administrative
-- shutdown in one decision. Shutdown then cancels and joins the engine before
-- returning.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local Signal = require('fibers.resource.signal')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local selected, detail, engine_exit

fibers.run(function(scope)
  local dispatch_commands = channel.new()
  local shutdown = channel.new()
  local idle = Signal.new('dispatch-engine-idle')

  local engine = scope:spawn(function()
    while true do
      local command = fibers.perform(Op.choice(dispatch_commands:get_op(), idle:wait_op()))
      if command == 'stop' then
        return 'dispatch engine stopped normally'
      end
    end
  end, 'dispatch-engine')

  scope:spawn(function()
    Sleep.sleep(1)
    shutdown:put('operations-centre maintenance')
  end, 'service-operator')

  selected, detail = fibers.perform(Op.named_choice({
    engine_exit = engine:body_result_op(),
    shutdown = shutdown:get_op(),
  }))

  if selected == 'shutdown' then
    engine:request_cancel(detail)
    engine_exit = fibers.perform(engine:body_result_op())
  else
    engine_exit = detail
  end
end, { host = Host.manual() })

assert(selected == 'shutdown')
assert(detail == 'operations-centre maintenance')
assert(engine_exit.tag == 'cancelled' or engine_exit.tag == 'failed')
print('selected:', selected, detail, 'dispatch engine:', engine_exit.tag)
