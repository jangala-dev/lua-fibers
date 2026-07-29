package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- The cinematic owns camera control until the gameplay controller accepts it.
-- Protocol state, the transfer of custody and the acknowledgement are one
-- transactional hand-off.

local fibers = require('fibers')
local Cell = require('fibers.resource.cell')
local Scope = require('fibers.scope')
local Stream = require('fibers.stream')

local director_end, gameplay_end = Stream.memory_pair({
  name = 'camera-control-link',
  capacity = 128,
})
local cinematic = Scope.new('opening-cinematic')
local gameplay = Scope.new('player-gameplay')
local camera_mode = Cell.new('cinematic', 'camera-mode')
local acknowledgement, gameplay_has_custody

local result = fibers.try_run(function()
  fibers.perform(cinematic:admit_op(gameplay_end))
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
  gameplay_has_custody = fibers.perform(gameplay:has_custody_op(gameplay_end))
end)

assert(result.ok)
assert(camera_mode.value == 'player')
assert(acknowledgement == 'CAMERA_READY')
assert(gameplay_has_custody)
print('camera:', camera_mode.value, 'custodian:', gameplay.name)
