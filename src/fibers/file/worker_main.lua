-- Standalone blocking regular-file worker. This file intentionally has no
-- Fibers dependencies: it runs in a helper process and communicates over
-- stdin/stdout using a strict length-framed protocol.

local argv = _G.arg or {}
local unpack_ = table.unpack or unpack

local ok_nixio, nixio = pcall(require, 'nixio')
local ok_nixio_fs, nixio_fs = pcall(require, 'nixio.fs')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_stdio, stdio = pcall(require, 'posix.stdio')
local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_stat, sys_stat = pcall(require, 'posix.sys.stat')
local ok_errno, posix_errno = pcall(require, 'posix.errno')
local ok_lfs, lfs = pcall(require, 'lfs')
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi then
  ok_ffi, ffi = pcall(require, 'cffi')
end
local ffi_C
if ok_ffi and type(ffi) == 'table' and type(ffi.cdef) == 'function' then
  pcall(function()
    ffi.cdef([[
      long read(int fd, void *buf, unsigned long count);
      long write(int fd, const void *buf, unsigned long count);
      int open(const char *path, int flags, ...);
      long lseek(int fd, long offset, int whence);
      int fsync(int fd);
      int fdatasync(int fd);
      int close(int fd);
      int mkdir(const char *path, unsigned int mode);
      int rename(const char *oldpath, const char *newpath);
      int unlink(const char *path);
      char *strerror(int errnum);
    ]])
  end)
  ffi_C = ffi.C
end

local errno_names =
  { [2] = 'ENOENT', [4] = 'EINTR', [13] = 'EACCES', [17] = 'EEXIST', [22] = 'EINVAL', [95] = 'ENOTSUP' }
local function add_errno_table(values)
  if type(values) ~= 'table' then
    return
  end
  for name, value in pairs(values) do
    if type(name) == 'string' and name:match('^E[A-Z0-9_]+$') and type(value) == 'number' then
      errno_names[value] = name
    end
  end
end
add_errno_table(ok_nixio and nixio.const or nil)
add_errno_table(ok_errno and posix_errno or nil)

local function write_all(bytes)
  local ok, err = io.stdout:write(bytes)
  if not ok then
    return nil, err
  end
  io.stdout:flush()
  return true
end

local function response_ok(value)
  if value == nil then
    return write_all('OK 0\n')
  end
  value = tostring(value)
  return write_all('OK ' .. tostring(#value) .. '\n' .. value)
end
local function response_data(value)
  value = value or ''
  return write_all('DATA ' .. tostring(#value) .. '\n' .. value)
end
local function response_error(code, message)
  code = tostring(code or 'EIO')
  message = tostring(message or 'file operation failed')
  return write_all('ERR ' .. tostring(#code) .. ' ' .. tostring(#message) .. '\n' .. code .. message)
end

local function read_exact(n)
  if n == 0 then
    return ''
  end
  local chunks, total = {}, 0
  while total < n do
    local chunk = io.stdin:read(n - total)
    if not chunk or chunk == '' then
      return nil, 'unexpected end of input'
    end
    chunks[#chunks + 1] = chunk
    total = total + #chunk
  end
  return table.concat(chunks)
end
local function line()
  return io.stdin:read('*l')
end

local function error_values(a, b, fallback)
  local message, number
  if type(a) == 'number' then
    number, message = a, b
  elseif type(b) == 'number' then
    message, number = a, b
  else
    message = a or b
  end
  if not number and ok_ffi and type(ffi.errno) == 'function' then
    local ok, value = pcall(ffi.errno)
    if ok then
      number = tonumber(value)
    end
  end
  if not number and ok_nixio and type(nixio.errno) == 'function' then
    local ok, value = pcall(nixio.errno)
    if ok then
      number = tonumber(value)
    end
  end
  local code = number and errno_names[number] or fallback or 'EIO'
  if not number and type(message) == 'string' then
    local lower = message:lower()
    if lower:match('exist') then
      code = 'EEXIST'
    elseif lower:match('no such') or lower:match('not found') then
      code = 'ENOENT'
    elseif lower:match('permission') or lower:match('denied') then
      code = 'EACCES'
    end
  end
  if not message and number and ok_nixio and type(nixio.strerror) == 'function' then
    local ok, value = pcall(nixio.strerror, number)
    if ok then
      message = value
    end
  end
  return code, tostring(message or code), number
end

local allowed_modes = {
  r = true,
  rb = true,
  w = true,
  wb = true,
  a = true,
  ab = true,
  ['r+'] = true,
  ['r+b'] = true,
  ['rb+'] = true,
  ['w+'] = true,
  ['w+b'] = true,
  ['wb+'] = true,
  ['a+'] = true,
  ['a+b'] = true,
  ['ab+'] = true,
}
local function parse_mode(mode)
  if not allowed_modes[mode] then
    return nil
  end
  local first = mode:sub(1, 1)
  return {
    name = mode,
    read = first == 'r' or mode:find('+', 1, true) ~= nil,
    write = first ~= 'r' or mode:find('+', 1, true) ~= nil,
    create = first == 'w' or first == 'a',
    truncate = first == 'w',
    append = first == 'a',
  }
end
local Handle = {}
Handle.__index = Handle

function Handle:read(count)
  if self.kind == 'posix' then
    return unistd.read(self.fd, count)
  end
  if self.kind == 'ffi' then
    local buffer = ffi.new('char[?]', math.max(count, 1))
    while true do
      local rc = tonumber(ffi_C.read(self.fd, buffer, count))
      if rc >= 0 then
        return rc == 0 and '' or ffi.string(buffer, rc)
      end
      local eno = ffi.errno()
      if eno ~= 4 then
        return nil, ffi.string(ffi_C.strerror(eno)), eno
      end
    end
  end
  return self.raw:read(count)
end
function Handle:write(bytes)
  if self.kind == 'posix' then
    return unistd.write(self.fd, bytes)
  end
  if self.kind == 'ffi' then
    local buffer = ffi.new('char[?]', math.max(#bytes, 1))
    if #bytes > 0 then
      ffi.copy(buffer, bytes, #bytes)
    end
    while true do
      local rc = tonumber(ffi_C.write(self.fd, buffer, #bytes))
      if rc >= 0 then
        return rc
      end
      local eno = ffi.errno()
      if eno ~= 4 then
        return nil, ffi.string(ffi_C.strerror(eno)), eno
      end
    end
  end
  if self.kind == 'nixio' then
    return self.raw:write(bytes, 0, #bytes)
  end
  local ok, err = self.raw:write(bytes)
  if not ok then
    return nil, err
  end
  return #bytes
end
function Handle:seek(whence, offset)
  if self.kind == 'posix' then
    local origins = { set = unistd.SEEK_SET, cur = unistd.SEEK_CUR, ['end'] = unistd.SEEK_END }
    return unistd.lseek(self.fd, offset, origins[whence])
  end
  if self.kind == 'ffi' then
    local origins = { set = 0, cur = 1, ['end'] = 2 }
    local rc = tonumber(ffi_C.lseek(self.fd, offset, origins[whence]))
    if rc >= 0 then
      return rc
    end
    local eno = ffi.errno()
    return nil, ffi.string(ffi_C.strerror(eno)), eno
  end
  if self.kind == 'nixio' then
    return self.raw:seek(offset, whence)
  end
  return self.raw:seek(whence, offset)
end
function Handle:flush()
  if self.kind == 'ffi' or self.kind == 'nixio' or self.kind == 'posix' then
    return true
  end
  return self.raw:flush()
end
function Handle:sync(data_only)
  if self.kind == 'ffi' then
    local fn = data_only and ffi_C.fdatasync or ffi_C.fsync
    local rc = tonumber(fn(self.fd))
    if rc == 0 then
      return true
    end
    local eno = ffi.errno()
    return nil, ffi.string(ffi_C.strerror(eno)), eno
  end
  if self.kind == 'nixio' then
    return self.raw:sync(data_only == true)
  end
  if self.kind == 'posix' then
    local fn = data_only and unistd.fdatasync or unistd.fsync
    if type(fn) ~= 'function' then
      fn = unistd.fsync
    end
    if type(fn) ~= 'function' then
      return nil, 'sync is unsupported', 'ENOTSUP'
    end
    local ok, err, eno = fn(self.fd)
    if ok == nil then
      local code, message = error_values(err, eno)
      return nil, message, code
    end
    return true
  end
  return nil, 'sync is unsupported by the worker interpreter', 'ENOTSUP'
end
function Handle:close()
  if self.kind == 'posix' then
    return unistd.close(self.fd)
  end
  if self.kind == 'ffi' then
    return tonumber(ffi_C.close(self.fd)) == 0
  end
  return self.raw:close()
end

local function sum_flags(values)
  local total = 0
  for i = 1, #values do
    total = total + values[i]
  end
  return total
end

local function nixio_flags(mode, exclusive)
  local names = {}
  if mode.read and mode.write then
    names[#names + 1] = 'rdwr'
  elseif mode.read then
    names[#names + 1] = 'rdonly'
  else
    names[#names + 1] = 'wronly'
  end
  if mode.create then
    names[#names + 1] = 'creat'
  end
  if mode.truncate then
    names[#names + 1] = 'trunc'
  end
  if mode.append then
    names[#names + 1] = 'append'
  end
  if exclusive then
    names[#names + 1] = 'creat'
    names[#names + 1] = 'excl'
  end
  return nixio.open_flags(unpack_(names))
end

local function posix_flags(mode, exclusive)
  local flags = {}
  flags[#flags + 1] = mode.read and mode.write and fcntl.O_RDWR
    or (mode.read and fcntl.O_RDONLY or fcntl.O_WRONLY)
  if mode.create then
    flags[#flags + 1] = fcntl.O_CREAT
  end
  if mode.truncate then
    flags[#flags + 1] = fcntl.O_TRUNC
  end
  if mode.append then
    flags[#flags + 1] = fcntl.O_APPEND
  end
  if exclusive then
    flags[#flags + 1] = fcntl.O_EXCL
  end
  if fcntl.O_CLOEXEC then
    flags[#flags + 1] = fcntl.O_CLOEXEC
  end
  return sum_flags(flags)
end

local function ffi_int(value)
  if ok_ffi and type(ffi.cast) == 'function' then
    local ok, converted = pcall(ffi.cast, 'int', value)
    if ok then
      return converted
    end
  end
  return value
end

local function ffi_flags(mode, exclusive)
  local flags = mode.read and mode.write and 2 or (mode.read and 0 or 1)
  if mode.create then
    flags = flags + 64
  end
  if mode.truncate then
    flags = flags + 512
  end
  if mode.append then
    flags = flags + 1024
  end
  if exclusive then
    flags = flags + 128
  end
  return flags + 0x80000
end

local function open_handle(path, mode, permissions, exclusive)
  mode = parse_mode(mode)
  if not mode then
    return nil, 'EINVAL', 'invalid file mode'
  end
  permissions = tonumber(permissions) or 420

  local rejected = {}
  local function rejected_by(name, err)
    rejected[#rejected + 1] = name .. ': ' .. tostring(err)
  end

  -- Prefer the stable Lua-level POSIX bindings in helper processes. A few
  -- luaposix/Lua combinations reject particular flag sets by raising a Lua
  -- argument error rather than returning errno. Treat that as an incompatible
  -- binding and try the next native adapter; ordinary filesystem errors remain
  -- authoritative and are returned immediately.
  if
    ok_fcntl
    and ok_unistd
    and type(fcntl.open) == 'function'
    and type(unistd.read) == 'function'
    and type(unistd.write) == 'function'
    and type(unistd.lseek) == 'function'
    and type(unistd.close) == 'function'
  then
    local called, fd, err, eno = pcall(fcntl.open, path, posix_flags(mode, exclusive), permissions)
    if called then
      if fd == nil then
        local code, message = error_values(err, eno, 'EOPEN')
        return nil, code, message
      end
      return setmetatable({ kind = 'posix', fd = fd }, Handle)
    end
    rejected_by('luaposix', fd)
  end

  if ok_nixio and type(nixio.open) == 'function' and type(nixio.open_flags) == 'function' then
    local flags_ok, flags = pcall(nixio_flags, mode, exclusive)
    if flags_ok then
      local called, raw, a, b = pcall(nixio.open, path, flags, permissions)
      if called then
        if not raw then
          local code, message = error_values(a, b, 'EOPEN')
          return nil, code, message
        end
        return setmetatable({ kind = 'nixio', raw = raw }, Handle)
      end
      rejected_by('nixio', raw)
    else
      rejected_by('nixio flags', flags)
    end
  end

  if ffi_C then
    local called, raw_fd = pcall(ffi_C.open, path, ffi_flags(mode, exclusive), ffi_int(permissions))
    if called then
      local fd = tonumber(raw_fd)
      if fd and fd >= 0 then
        return setmetatable({ kind = 'ffi', fd = fd }, Handle)
      end
      local eno = ffi.errno()
      return nil, errno_names[eno] or 'EOPEN', ffi.string(ffi_C.strerror(eno))
    end
    rejected_by('ffi', raw_fd)
  end

  if exclusive or permissions ~= 420 then
    local detail = #rejected > 0 and (': ' .. table.concat(rejected, '; ')) or ''
    return nil,
      'ENOTSUP',
      'exclusive creation or explicit permissions require a compatible native file adapter' .. detail
  end
  local raw, err = io.open(path, mode.name)
  if not raw then
    return nil, 'EOPEN', err
  end
  if raw.setvbuf then
    raw:setvbuf('no')
  end
  return setmetatable({ kind = 'lua', raw = raw }, Handle)
end

local function handle_mode(mode, path, permissions, exclusive)
  local handle, code, err = open_handle(path, mode, permissions, exclusive == '1')
  if not handle then
    response_error(code, err)
    -- Keep the helper alive until the parent has drained the final response and
    -- closes stdin. Some process hosts otherwise close the child and close its
    -- stdout endpoint before the buffered error frame is consumed.
    line()
    return 0
  end
  response_ok()
  while true do
    local request = line()
    if not request then
      handle:close()
      return 0
    end
    local op, rest = request:match('^(%S+)%s*(.*)$')
    if op == 'READ' then
      local count = tonumber(rest)
      if not count or count < 0 or count ~= math.floor(count) then
        response_error('EINVAL', 'READ expects a non-negative integer')
      else
        local data, a, b = handle:read(count)
        if data == nil and a ~= nil then
          local ec, em = error_values(a, b, 'EREAD')
          response_error(ec, em)
        else
          response_data(data or '')
        end
      end
    elseif op == 'WRITE' then
      local count = tonumber(rest)
      if not count or count < 0 or count ~= math.floor(count) then
        response_error('EINVAL', 'WRITE expects a non-negative integer')
      else
        local bytes, input_err = read_exact(count)
        if not bytes then
          response_error('EPROTO', input_err)
        else
          local written, a, b = handle:write(bytes)
          if written == nil then
            local ec, em = error_values(a, b, 'EWRITE')
            response_error(ec, em)
          else
            response_ok(written)
          end
        end
      end
    elseif op == 'SEEK' then
      local whence, offset = rest:match('^(%S+)%s+([+-]?%d+)$')
      offset = tonumber(offset)
      local position, a, b = handle:seek(whence, offset)
      if position == nil then
        local ec, em = error_values(a, b, 'ESEEK')
        response_error(ec, em)
      else
        response_ok(position)
      end
    elseif op == 'FLUSH' then
      local ok, a, b = handle:flush()
      if not ok then
        local ec, em = error_values(a, b, 'EFLUSH')
        response_error(ec, em)
      else
        response_ok()
      end
    elseif op == 'SYNC' then
      local ok, a, b = handle:sync(rest == '1')
      if not ok then
        local code, message
        if type(b) == 'string' and b:match('^E') then
          code, message = b, a
        else
          code, message = error_values(a, b, 'ESYNC')
        end
        response_error(code, message)
      else
        response_ok()
      end
    elseif op == 'CLOSE' then
      local ok, a, b = handle:close()
      if not ok then
        local ec, em = error_values(a, b, 'ECLOSE')
        response_error(ec, em)
      else
        response_ok()
      end
      return ok and 0 or 1
    else
      response_error('EPROTO', 'unknown request ' .. tostring(op))
    end
  end
end

local function native_rename(from, to)
  if ok_stdio and type(stdio.rename) == 'function' then
    return stdio.rename(from, to)
  end
  if ok_nixio_fs and type(nixio_fs.rename) == 'function' then
    return nixio_fs.rename(from, to)
  end
  if ffi_C then
    local rc = tonumber(ffi_C.rename(from, to))
    if rc == 0 then
      return true
    end
    return nil, nil, ffi.errno()
  end
  return os.rename(from, to)
end
local function native_unlink(path)
  if ok_unistd and type(unistd.unlink) == 'function' then
    return unistd.unlink(path)
  end
  if ok_nixio_fs and type(nixio_fs.unlink) == 'function' then
    return nixio_fs.unlink(path)
  end
  if ffi_C then
    local rc = tonumber(ffi_C.unlink(path))
    if rc == 0 then
      return true
    end
    return nil, nil, ffi.errno()
  end
  return os.remove(path)
end
local function native_mkdir(path, permissions)
  permissions = tonumber(permissions) or 493
  if ok_stat and type(sys_stat.mkdir) == 'function' then
    return sys_stat.mkdir(path, permissions)
  end
  if ok_nixio_fs and type(nixio_fs.mkdir) == 'function' then
    return nixio_fs.mkdir(path, permissions)
  end
  if ffi_C then
    local rc = tonumber(ffi_C.mkdir(path, permissions))
    if rc == 0 then
      return true
    end
    return nil, nil, ffi.errno()
  end
  if ok_lfs and type(lfs.mkdir) == 'function' then
    if permissions ~= 493 then
      return nil, 'explicit directory permissions require Nixio or luaposix', 'ENOTSUP'
    end
    return lfs.mkdir(path)
  end
  return nil, 'directory creation requires FFI, Nixio, luaposix or LuaFileSystem', 'ENOTSUP'
end
local function native_mkdir_p(path, permissions)
  permissions = tonumber(permissions) or 493
  if ok_nixio_fs and type(nixio_fs.mkdirr) == 'function' then
    return nixio_fs.mkdirr(path, permissions)
  end
  local absolute = path:sub(1, 1) == '/'
  local current = absolute and '/' or ''
  for part in path:gmatch('[^/]+') do
    current = (current == '' or current == '/') and (current .. part) or (current .. '/' .. part)
    local ok, a, b = native_mkdir(current, permissions)
    if not ok then
      local code, message = error_values(a, b, 'EMKDIR')
      if code ~= 'EEXIST' then
        return nil, message, code
      end
    end
  end
  return true
end

local function path_mode(action, args)
  local ok, a, b
  if action == 'RENAME' then
    ok, a, b = native_rename(args[1], args[2])
  elseif action == 'UNLINK' then
    ok, a, b = native_unlink(args[1])
  elseif action == 'MKDIR' then
    ok, a, b = native_mkdir(args[1], args[2])
  elseif action == 'MKDIRP' then
    ok, a, b = native_mkdir_p(args[1], args[2])
  else
    response_error('EINVAL', 'unknown path action')
    return 2
  end
  if not ok then
    local code, message
    if type(b) == 'string' and b:match('^E') then
      code, message = b, a
    else
      code, message = error_values(a, b, 'E' .. action)
    end
    response_error(code, message)
    return 1
  end
  response_ok()
  return 0
end

local function main()
  local mode = argv[1]
  if mode == 'handle' then
    return handle_mode(argv[2], argv[3], argv[4], argv[5])
  end
  if mode == 'path' then
    return path_mode(argv[2], { argv[3], argv[4], argv[5] })
  end
  response_error('EINVAL', 'worker expects handle or path mode')
  return 2
end

local ok, status = xpcall(main, function(err)
  if debug and debug.traceback then
    return debug.traceback(err, 2)
  end
  return tostring(err)
end)
if not ok then
  response_error('EWORKER', status)
  line()
  status = 0
end
os.exit(status or 0)
