package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A cutscene owns its camera, dialogue and animation work. Skipping chooses the
-- exit path, requests cancellation of the losing work and waits until every
-- Task held by the scene Lifetime has actually stopped.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local ManualHost = require('fibers.embed.manual')

local selected, reason
local camera_exit, dialogue_exit, animation_exit

fibers.run(function(scope)
  local camera = scope:spawn(function()
    Sleep.sleep(10)
    return 'camera track complete'
  end, 'cinematic-camera')

  local dialogue = scope:spawn(function()
    Sleep.sleep(8)
    return 'dialogue complete'
  end, 'cinematic-dialogue')

  local animation = scope:spawn(function()
    Sleep.sleep(6)
    return 'character animation complete'
  end, 'cinematic-animation')

  selected, reason = fibers.perform(Op.named_choice({
    finished = Sleep.sleep_op(6):map(function()
      return 'the final shot landed'
    end),
    skipped = Sleep.sleep_op(1):map(function()
      return 'the player pressed Skip'
    end),
  }))

  if selected == 'skipped' then
    camera:request_cancel(reason)
    dialogue:request_cancel(reason)
    animation:request_cancel(reason)
  end

  camera_exit = fibers.perform(camera:body_result_op())
  dialogue_exit = fibers.perform(dialogue:body_result_op())
  animation_exit = fibers.perform(animation:body_result_op())
end, { host = ManualHost.new() })

assert(selected == 'skipped')
assert(camera_exit.tag == 'cancelled')
assert(dialogue_exit.tag == 'cancelled')
assert(animation_exit.tag == 'cancelled')
print('cutscene:', selected, '-', reason)
