-- Public resource-facing multi-value row helpers.

local Kernel = require('et.kernel')
local Util = Kernel.Util

return {
  pack = Util.pack,
  unpack = Util.unpack,
  copy = Util.copy_row,
}
