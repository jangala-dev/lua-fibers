local NativeFile = require('fibers.file.internal.native_sync')

local function temp_path(suffix)
  local base = os.tmpname()
  pcall(os.remove, base)
  return base .. (suffix or '')
end

local invalid, invalid_err = NativeFile.open('/unused', 'not-a-mode', {})
assert(invalid == nil)
assert(type(invalid_err) == 'table' and invalid_err.code == 'EINVAL')

local path = temp_path('-fibers-native-sync')
local renamed = path .. '-renamed'
local handle, err = NativeFile.open(path, 'w+b', {})
assert(handle, err and err.message)
assert(handle:write('abcdef') == 6)
assert(handle:seek('set', 1) == 1)
assert(handle:read(3) == 'bcd')
assert(handle:flush())
local synced, sync_err = handle:sync(false)
assert(synced or (sync_err and sync_err.code == 'ENOTSUP'))
assert(handle:close())

assert(NativeFile.rename(path, renamed))
local reader = assert(NativeFile.open(renamed, 'rb', {}))
assert(reader:read(6) == 'abcdef')
assert(reader:close())
assert(NativeFile.unlink(renamed))

print('native synchronous file adapter tests: ok')
