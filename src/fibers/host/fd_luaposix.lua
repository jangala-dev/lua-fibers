-- Numeric descriptor family for luaposix.

local Errors = require('fibers.flow.errors')
local Family = require('fibers.host.family')
local FdClass = require('fibers.host.fd_class')
local HostError = require('fibers.host.error')
local BitOps = require('fibers.internal.bitops')

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_errno, errno = pcall(require, 'posix.errno')
local ok_socket, socket = pcall(require, 'posix.sys.socket')
local bit, bit_error = BitOps.resolve()
if
  not ok_unistd
  or type(unistd) ~= 'table'
  or not ok_fcntl
  or type(fcntl) ~= 'table'
  or not ok_errno
  or type(errno) ~= 'table'
then
  return Family.unsupported('fibers.host.fd_luaposix', 'luaposix unistd/fcntl/errno not available')
end
if not bit then
  return Family.unsupported('fibers.host.fd_luaposix', bit_error)
end

local PosixError = require('fibers.host.luaposix_error')
local EAGAIN = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK or EAGAIN

local function set_flag(fd, get, set, flag, value, label)
  local flags, err, eno = fcntl.fcntl(fd, get)
  if flags == nil then
    return nil, PosixError.message(label .. '(get)', err, eno), eno
  end
  local next_flags = value ~= false and bit.bor(flags, flag) or bit.band(flags, bit.bnot(flag))
  local ok, err2, eno2 = fcntl.fcntl(fd, set, next_flags)
  if ok == nil then
    return nil, PosixError.message(label .. '(set)', err2, eno2), eno2
  end
  return true
end

local function set_nonblocking(fd, value)
  return set_flag(fd, fcntl.F_GETFL, fcntl.F_SETFL, fcntl.O_NONBLOCK or 0, value, 'fcntl nonblocking')
end

local function set_cloexec(fd, value)
  if fcntl.F_GETFD == nil or fcntl.F_SETFD == nil or fcntl.FD_CLOEXEC == nil then
    return true
  end
  return set_flag(fd, fcntl.F_GETFD, fcntl.F_SETFD, fcntl.FD_CLOEXEC, value, 'fcntl cloexec')
end

local operations = {}
function operations.read(self, max)
  max = tonumber(max) or 4096
  if max <= 0 then
    return ''
  end
  local bytes, err, eno = unistd.read(self.fd, max)
  if bytes == nil then
    if eno == EAGAIN or eno == EWOULDBLOCK then
      return nil, 'would_block', eno
    end
    return nil, PosixError.message('read failed', err, eno), eno
  end
  if bytes == '' then
    return nil, Errors.EOF
  end
  return bytes
end
function operations.write(self, bytes)
  if type(bytes) ~= 'string' then
    error('fd write expects bytes', 2)
  end
  if bytes == '' then
    return 0
  end
  local count, err, eno = unistd.write(self.fd, bytes)
  if count == nil then
    if eno == EAGAIN or eno == EWOULDBLOCK then
      return nil, 'would_block', eno
    end
    return nil, PosixError.message('write failed', err, eno), eno
  end
  return count
end
function operations.shutdown_read(self)
  if ok_socket and type(socket.shutdown) == 'function' then
    pcall(socket.shutdown, self.fd, socket.SHUT_RD or 0)
  end
  return true
end
function operations.shutdown_write(self)
  if ok_socket and type(socket.shutdown) == 'function' then
    pcall(socket.shutdown, self.fd, socket.SHUT_WR or 1)
  end
  return true
end
function operations.close(self)
  if self._closed then
    return true
  end
  self._closed = true
  local ok, err, eno = unistd.close(self.fd)
  if ok == nil then
    return nil, PosixError.message('close failed', err, eno), eno
  end
  return true
end
function operations.set_nonblocking(self, value)
  return set_nonblocking(self.fd, value)
end

return FdClass.define({
  family = 'numeric-fd',
  operations = operations,
  is_supported = function()
    return type(unistd.read) == 'function'
      and type(unistd.write) == 'function'
      and type(unistd.close) == 'function'
      and type(unistd.pipe) == 'function'
  end,
  support_reason = function()
    return 'required luaposix fd functions unavailable'
  end,
  validate = function(fd)
    return assert(tonumber(fd), 'fd must be numeric')
  end,
  describe = function(fd, generation)
    return {
      name = 'posix-fd-' .. tostring(fd),
      key = { family = 'numeric-fd', fd = fd, generation = generation },
    }
  end,
  decorate = function(handle, fd)
    handle.fd, handle.raw_fd = fd, fd
  end,
  configure = function(handle, opts)
    if opts.cloexec ~= false then
      local ok, err, extra = set_cloexec(handle.fd, true)
      if not ok then
        return nil, err, extra
      end
    end
    if opts.nonblocking ~= false then
      return handle:set_nonblocking(true)
    end
    return true
  end,
  pipe = function()
    local read_fd, write_fd, err, eno = unistd.pipe()
    if not read_fd then
      return nil,
        nil,
        HostError.system('pipe', 'create', PosixError.message('pipe failed', err, eno), nil, eno),
        eno
    end
    return read_fd, write_fd
  end,
  close_raw = function(fd)
    pcall(unistd.close, fd)
  end,
})
