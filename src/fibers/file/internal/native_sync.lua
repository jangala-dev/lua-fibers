-- Blocking native regular-file adapter used by helper processes.
-- This module has no Fibers runtime dependency and performs no scheduling.

local unpack_ = table.unpack or unpack
local FileMode = require('fibers.file.internal.mode')

local ok_nixio, nixio = pcall(require, 'nixio')
local ok_nixio_fs, nixio_fs = pcall(require, 'nixio.fs')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_stdio, stdio = pcall(require, 'posix.stdio')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_stat, sys_stat = pcall(require, 'posix.sys.stat')
local ok_errno, posix_errno = pcall(require, 'posix.errno')
local ok_lfs, lfs = pcall(require, 'lfs')
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi then ok_ffi, ffi = pcall(require, 'cffi') end

local C
if ok_ffi and type(ffi) == 'table' and type(ffi.cdef) == 'function' then
  pcall(function()
    ffi.cdef([[
      long read(int fd, void *buf, unsigned long count);
      long write(int fd, const void *buf, unsigned long count);
      int open(const char *path, int flags, ...);
      long lseek(int fd, long offset, int whence);
      int fsync(int fd); int fdatasync(int fd); int close(int fd);
      int mkdir(const char *path, unsigned int mode);
      int rename(const char *oldpath, const char *newpath);
      int unlink(const char *path); char *strerror(int errnum);
    ]])
  end)
  C = ffi.C
end

local errno_names = {
  [2] = 'ENOENT', [4] = 'EINTR', [13] = 'EACCES', [17] = 'EEXIST',
  [22] = 'EINVAL', [95] = 'ENOTSUP',
}
local function add_errno_names(values)
  for name, value in pairs(values or {}) do
    if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
      errno_names[value] = name
    end
  end
end
add_errno_names(ok_nixio and nixio.const or nil)
add_errno_names(ok_errno and posix_errno or nil)

local function current_errno()
  if ok_ffi and type(ffi.errno) == 'function' then
    local ok, value = pcall(ffi.errno)
    if ok and tonumber(value) then return tonumber(value) end
  end
  if ok_nixio and type(nixio.errno) == 'function' then
    local ok, value = pcall(nixio.errno)
    if ok and tonumber(value) then return tonumber(value) end
  end
end

local function failure(a, b, fallback)
  local message, number
  if type(a) == 'number' then number, message = a, b
  elseif type(b) == 'number' then message, number = a, b
  else message = a or b end
  number = tonumber(number) or current_errno()
  local code = number and errno_names[number] or fallback or 'EIO'
  if not number and type(message) == 'string' then
    local lower = message:lower()
    if lower:match('exist') then code = 'EEXIST'
    elseif lower:match('no such') or lower:match('not found') then code = 'ENOENT'
    elseif lower:match('permission') or lower:match('denied') then code = 'EACCES' end
  end
  if not message and number and ok_nixio and type(nixio.strerror) == 'function' then
    local ok, value = pcall(nixio.strerror, number)
    if ok then message = value end
  end
  return { code = code, message = tostring(message or code), number = number }
end

local function unsupported(message)
  return { code = 'ENOTSUP', message = message }
end
local function ffi_failure(number, fallback)
  return failure(ffi.string(C.strerror(number)), number, fallback)
end

local parse_mode = FileMode.parse

local Handle = {}
Handle.__index = Handle


function Handle:read(count)
  if self.kind == 'posix' then
    local value, a, b = unistd.read(self.fd, count)
    if value == nil and a == nil and b == nil then return '' end
    return value ~= nil and value or nil, value == nil and failure(a, b, 'EREAD') or nil
  elseif self.kind == 'ffi' then
    local buffer = ffi.new('char[?]', math.max(count, 1))
    while true do
      local rc = tonumber(C.read(self.fd, buffer, count))
      if rc >= 0 then return rc == 0 and '' or ffi.string(buffer, rc) end
      local eno = ffi.errno()
      if eno ~= 4 then return nil, ffi_failure(eno, 'EREAD') end
    end
  end
  local value, a, b = self.raw:read(count)
  if value == nil and a == nil and b == nil then return '' end
  return value ~= nil and value or nil, value == nil and failure(a, b, 'EREAD') or nil
end

function Handle:write(bytes)
  if self.kind == 'posix' then
    local value, a, b = unistd.write(self.fd, bytes)
    return value ~= nil and value or nil, value == nil and failure(a, b, 'EWRITE') or nil
  elseif self.kind == 'ffi' then
    local buffer = ffi.new('char[?]', math.max(#bytes, 1))
    if #bytes > 0 then ffi.copy(buffer, bytes, #bytes) end
    while true do
      local rc = tonumber(C.write(self.fd, buffer, #bytes))
      if rc >= 0 then return rc end
      local eno = ffi.errno()
      if eno ~= 4 then return nil, ffi_failure(eno, 'EWRITE') end
    end
  elseif self.kind == 'nixio' then
    local value, a, b = self.raw:write(bytes, 0, #bytes)
    return value ~= nil and value or nil, value == nil and failure(a, b, 'EWRITE') or nil
  end
  local ok, err = self.raw:write(bytes)
  if not ok then return nil, failure(err, nil, 'EWRITE') end
  return #bytes
end

function Handle:seek(whence, offset)
  if self.kind == 'posix' then
    local origins = { set = unistd.SEEK_SET, cur = unistd.SEEK_CUR, ['end'] = unistd.SEEK_END }
    local value, a, b = unistd.lseek(self.fd, offset, origins[whence])
    return value ~= nil and value or nil, value == nil and failure(a, b, 'ESEEK') or nil
  elseif self.kind == 'ffi' then
    local origins = { set = 0, cur = 1, ['end'] = 2 }
    local rc = tonumber(C.lseek(self.fd, offset, origins[whence]))
    if rc >= 0 then return rc end
    return nil, ffi_failure(ffi.errno(), 'ESEEK')
  elseif self.kind == 'nixio' then
    local value, a, b = self.raw:seek(offset, whence)
    return value ~= nil and value or nil, value == nil and failure(a, b, 'ESEEK') or nil
  end
  local value, err = self.raw:seek(whence, offset)
  return value ~= nil and value or nil, value == nil and failure(err, nil, 'ESEEK') or nil
end

function Handle:flush()
  if self.kind ~= 'lua' then return true end
  local ok, a, b = self.raw:flush()
  if ok then return true end
  return nil, failure(a, b, 'EFLUSH')
end

function Handle:sync(data_only)
  if self.kind == 'ffi' then
    local fn = data_only and C.fdatasync or C.fsync
    if tonumber(fn(self.fd)) == 0 then return true end
    return nil, ffi_failure(ffi.errno(), 'ESYNC')
  elseif self.kind == 'nixio' then
    local ok, a, b = self.raw:sync(data_only == true)
    if ok then return true end
    return nil, failure(a, b, 'ESYNC')
  elseif self.kind == 'posix' then
    local fn = data_only and unistd.fdatasync or unistd.fsync
    if type(fn) ~= 'function' then fn = unistd.fsync end
    if type(fn) ~= 'function' then return nil, unsupported('sync is unsupported') end
    local ok, a, b = fn(self.fd)
    if ok ~= nil and ok ~= false then return true end
    return nil, failure(a, b, 'ESYNC')
  end
  return nil, unsupported('sync is unsupported by the worker interpreter')
end

function Handle:close()
  if self.kind == 'posix' then
    local ok, a, b = unistd.close(self.fd)
    if ok ~= nil and ok ~= false then return true end
    return nil, failure(a, b, 'ECLOSE')
  elseif self.kind == 'ffi' then
    if tonumber(C.close(self.fd)) == 0 then return true end
    return nil, ffi_failure(ffi.errno(), 'ECLOSE')
  end
  local ok, a, b = self.raw:close()
  if ok ~= nil and ok ~= false then return true end
  return nil, failure(a, b, 'ECLOSE')
end

local function sum(values)
  local total = 0
  for i = 1, #values do total = total + values[i] end
  return total
end
local function nixio_flags(mode, exclusive)
  local names = { mode.read and mode.write and 'rdwr' or (mode.read and 'rdonly' or 'wronly') }
  if mode.create then names[#names + 1] = 'creat' end
  if mode.truncate then names[#names + 1] = 'trunc' end
  if mode.append then names[#names + 1] = 'append' end
  if exclusive then names[#names + 1], names[#names + 2] = 'creat', 'excl' end
  return nixio.open_flags(unpack_(names))
end
local function posix_flags(mode, exclusive)
  local flags = { mode.read and mode.write and fcntl.O_RDWR or (mode.read and fcntl.O_RDONLY or fcntl.O_WRONLY) }
  if mode.create then flags[#flags + 1] = fcntl.O_CREAT end
  if mode.truncate then flags[#flags + 1] = fcntl.O_TRUNC end
  if mode.append then flags[#flags + 1] = fcntl.O_APPEND end
  if exclusive then flags[#flags + 1] = fcntl.O_EXCL end
  if fcntl.O_CLOEXEC then flags[#flags + 1] = fcntl.O_CLOEXEC end
  return sum(flags)
end
local function ffi_flags(mode, exclusive)
  local flags = mode.read and mode.write and 2 or (mode.read and 0 or 1)
  if mode.create then flags = flags + 64 end
  if mode.truncate then flags = flags + 512 end
  if mode.append then flags = flags + 1024 end
  if exclusive then flags = flags + 128 end
  return flags + 0x80000
end
local function ffi_int(value)
  if ok_ffi and type(ffi.cast) == 'function' then
    local ok, converted = pcall(ffi.cast, 'int', value)
    if ok then return converted end
  end
  return value
end

local NativeFile = {}

function NativeFile.open(path, name, opts)
  local mode = parse_mode(name)
  if not mode then return nil, { code = 'EINVAL', message = 'invalid file mode' } end
  opts = opts or {}
  local permissions, exclusive = tonumber(opts.permissions) or 420, opts.exclusive == true
  local rejected = {}
  local function reject(adapter, err) rejected[#rejected + 1] = adapter .. ': ' .. tostring(err) end

  if ok_fcntl and ok_unistd and type(fcntl.open) == 'function' and type(unistd.read) == 'function'
      and type(unistd.write) == 'function' and type(unistd.lseek) == 'function' and type(unistd.close) == 'function' then
    local called, fd, a, b = pcall(fcntl.open, path, posix_flags(mode, exclusive), permissions)
    if called then
      if fd == nil then return nil, failure(a, b, 'EOPEN') end
      return setmetatable({ kind = 'posix', fd = fd }, Handle)
    end
    reject('luaposix', fd)
  end

  if ok_nixio and type(nixio.open) == 'function' and type(nixio.open_flags) == 'function' then
    local flags_ok, flags = pcall(nixio_flags, mode, exclusive)
    if flags_ok then
      local called, raw, a, b = pcall(nixio.open, path, flags, permissions)
      if called then
        if not raw then return nil, failure(a, b, 'EOPEN') end
        return setmetatable({ kind = 'nixio', raw = raw }, Handle)
      end
      reject('nixio', raw)
    else
      reject('nixio flags', flags)
    end
  end

  if C then
    local called, raw_fd = pcall(C.open, path, ffi_flags(mode, exclusive), ffi_int(permissions))
    if called then
      local fd = tonumber(raw_fd)
      if fd and fd >= 0 then return setmetatable({ kind = 'ffi', fd = fd }, Handle) end
      return nil, ffi_failure(ffi.errno(), 'EOPEN')
    end
    reject('ffi', raw_fd)
  end

  if exclusive or permissions ~= 420 then
    local detail = #rejected > 0 and (': ' .. table.concat(rejected, '; ')) or ''
    return nil, unsupported('exclusive creation or explicit permissions require a compatible native file adapter' .. detail)
  end
  local raw, err = io.open(path, mode.name)
  if not raw then return nil, failure(err, nil, 'EOPEN') end
  if raw.setvbuf then raw:setvbuf('no') end
  return setmetatable({ kind = 'lua', raw = raw }, Handle)
end

function NativeFile.rename(from, to)
  local ok, a, b
  if ok_stdio and type(stdio.rename) == 'function' then ok, a, b = stdio.rename(from, to)
  elseif ok_nixio_fs and type(nixio_fs.rename) == 'function' then ok, a, b = nixio_fs.rename(from, to)
  elseif C then
    if tonumber(C.rename(from, to)) == 0 then return true end
    return nil, failure(ffi.errno(), nil, 'ERENAME')
  else ok, a, b = os.rename(from, to) end
  if ok then return true end
  return nil, failure(a, b, 'ERENAME')
end

function NativeFile.unlink(path)
  local ok, a, b
  if ok_unistd and type(unistd.unlink) == 'function' then ok, a, b = unistd.unlink(path)
  elseif ok_nixio_fs and type(nixio_fs.unlink) == 'function' then ok, a, b = nixio_fs.unlink(path)
  elseif C then
    if tonumber(C.unlink(path)) == 0 then return true end
    return nil, failure(ffi.errno(), nil, 'EUNLINK')
  else ok, a, b = os.remove(path) end
  if ok then return true end
  return nil, failure(a, b, 'EUNLINK')
end

function NativeFile.mkdir(path, permissions)
  permissions = tonumber(permissions) or 493
  local ok, a, b
  if ok_stat and type(sys_stat.mkdir) == 'function' then ok, a, b = sys_stat.mkdir(path, permissions)
  elseif ok_nixio_fs and type(nixio_fs.mkdir) == 'function' then ok, a, b = nixio_fs.mkdir(path, permissions)
  elseif C then
    if tonumber(C.mkdir(path, permissions)) == 0 then return true end
    return nil, failure(ffi.errno(), nil, 'EMKDIR')
  elseif ok_lfs and type(lfs.mkdir) == 'function' then
    if permissions ~= 493 then return nil, unsupported('explicit directory permissions require Nixio or luaposix') end
    ok, a, b = lfs.mkdir(path)
  else
    return nil, unsupported('directory creation requires FFI, Nixio, luaposix or LuaFileSystem')
  end
  if ok then return true end
  return nil, failure(a, b, 'EMKDIR')
end

function NativeFile.mkdir_p(path, permissions)
  permissions = tonumber(permissions) or 493
  if ok_nixio_fs and type(nixio_fs.mkdirr) == 'function' then
    local ok, a, b = nixio_fs.mkdirr(path, permissions)
    if ok then return true end
    return nil, failure(a, b, 'EMKDIRP')
  end
  local absolute, current = path:sub(1, 1) == '/', ''
  if absolute then current = '/' end
  for part in path:gmatch('[^/]+') do
    current = (current == '' or current == '/') and (current .. part) or (current .. '/' .. part)
    local ok, err = NativeFile.mkdir(current, permissions)
    if not ok and err.code ~= 'EEXIST' then return nil, err end
  end
  return true
end

return NativeFile
