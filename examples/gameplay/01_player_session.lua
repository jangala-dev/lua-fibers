package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A player session is a lifetime boundary. Profile refresh, character
-- observation and quest delivery cannot outlive the player who owns them.

local fibers = require('fibers')
local Sleep = require('fibers.sleep')
local Op = require('fibers.op')
local Pulse = require('fibers.pulse')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local player_left = channel.new()
local refreshes = 0
local session_reason

fibers.run(function(root)
  root:spawn(function()
    Sleep.sleep(3)
    player_left:put('Mira left the server')
  end, 'simulate-player-leaving')

  session_reason = fibers.scope({ name = 'player:Mira' }, function(scope)
    local session_ending = Pulse.new({ name = 'player:Mira:ending' })

    local function run_until_session_ends(name, on_tick)
      scope:spawn(function()
        while true do
          local selected, reason = fibers.perform(Op.named_choice({
            tick = Sleep.sleep_op(1),
            ending = session_ending:changed_op(0),
          }))
          if selected == 'ending' then
            return reason
          end
          on_tick()
        end
      end, name)
    end

    run_until_session_ends('profile-lock-refresh', function()
      refreshes = refreshes + 1
    end)
    run_until_session_ends('character-lifetime', function() end)
    run_until_session_ends('quest-delivery', function() end)

    local reason = player_left:get()
    session_ending:close(reason)
    return reason
  end)
end, { host = Host.manual() })

assert(session_reason == 'Mira left the server')
assert(refreshes == 3)
print('session closed:', session_reason, 'profile refreshes:', refreshes)
