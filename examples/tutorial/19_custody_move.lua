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
local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')
local Scope = require('fibers.scope')
local Stream = require('fibers.stream')

local director_end, gameplay_end = Stream.memory_pair({
  label = 'camera-control-link',
  capacity = 128,
})
local cinematic = Scope.new():label('opening-cinematic')
local gameplay = Scope.new():label('player-gameplay')
local camera_mode = Cell.new('cinematic'):label('camera-mode')
local acknowledgement, gameplay_has_custody, final_camera_mode

local result = fibers.try_run(function()
  fibers.perform(cinematic:admit_op(gameplay_end))
  fibers.perform(director_end:writer():write_op('RELEASE_CAMERA\n'))

  fibers.perform(gameplay_end:reader():read_line_op():and_then(Op.guard(function(message)
    if message ~= 'RELEASE_CAMERA' then
      return gameplay_end:request_close_op('unexpected camera protocol')
    end
    return camera_mode
      :write_op('player')
      :and_then(cinematic:move_op(gameplay_end, gameplay))
      :and_then(gameplay_end:writer():write_op('CAMERA_READY\n'))
  end)))

  acknowledgement = fibers.perform(director_end:reader():read_line_op())
  gameplay_has_custody = fibers.perform(gameplay:has_custody_op(gameplay_end))
  final_camera_mode = camera_mode:read()
end)

assert(result.ok)
assert(final_camera_mode == 'player')
assert(acknowledgement == 'CAMERA_READY')
assert(gameplay_has_custody)
print('camera:', final_camera_mode, 'custodian:', gameplay.name)
