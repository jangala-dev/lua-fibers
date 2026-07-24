package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A follow-up input and the closing of the combo window are simply two possible
-- events. Neither event needs bespoke cancellation plumbing.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local channel = require('fibers.channel')
local Host = require('fibers.host')

local follow_up = channel.new()
local selected, move

fibers.run(function(scope)
  scope:spawn(function()
    Sleep.sleep(1)
    follow_up:put('crescent uppercut')
  end, 'simulate-player-input')

  selected, move = fibers.perform(Op.named_choice({
    input = follow_up:get_op(),
    expired = Sleep.sleep_op(2):map(function()
      return 'return to neutral stance'
    end),
  }))
end, { host = Host.manual() })

assert(selected == 'input')
assert(move == 'crescent uppercut')
print('combo:', selected, move)
