package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Camera mode, the protocol acknowledgement and transfer of custody move
-- together. Gameplay cannot observe a half-completed cinematic hand-off.

local fibers = require('fibers')
local Scalar = require('fibers.resource.scalar')
local Scope = require('fibers.scope')
local Stream = require('fibers.stream')

local director_end, gameplay_end = Stream.memory_pair({
  name = 'camera-control-link',
  capacity = 128,
})
local cinematic = Scope.new('opening-cinematic')
local gameplay = Scope.new('player-gameplay')
local camera_mode = Scalar.new('cinematic', 'camera-mode')
local acknowledgement

local result = fibers.try_run(function()
  fibers.perform(cinematic:raw_region():admit_op(gameplay_end))
  fibers.perform(director_end:writer():write_op('RELEASE_CAMERA\n'))

  fibers.perform(gameplay_end:reader():read_line_op():and_then(function(message)
    if message ~= 'RELEASE_CAMERA' then
      return gameplay_end:close_op('unexpected camera protocol')
    end
    return camera_mode
      :write_op('player')
      :and_then(function()
        return cinematic:move_op(gameplay_end, gameplay)
      end)
      :and_then(function()
        return gameplay_end:writer():write_op('CAMERA_READY\n')
      end)
  end))

  acknowledgement = fibers.perform(director_end:reader():read_line_op())
end)

assert(result.ok)
assert(camera_mode.value == 'player')
assert(acknowledgement == 'CAMERA_READY')
assert(gameplay_end.owner == gameplay:raw_region())
print('camera:', camera_mode.value, 'owner:', gameplay_end.owner.name)
