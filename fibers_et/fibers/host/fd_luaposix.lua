-- luaposix fd HostHandle implementation.
--
-- Optional.  Provides wrap(fd) and pipe() over numeric POSIX file descriptors.

local Handle = require('fibers.host.handle')
local Errors = require('fibers.facility.flow.errors')

local function unsupported(reason)
  return {
    is_supported = function() return false, reason end,
    support_reason = function() return reason end,
    new = function() error('fibers.host.fd_luaposix: ' .. tostring(reason), 2) end,
    wrap = function() error('fibers.host.fd_luaposix: ' .. tostring(reason), 2) end,
    pipe = function() error('fibers.host.fd_luaposix: ' .. tostring(reason), 2) end,
  }
end

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_errno, errno = pcall(require, 'posix.errno')
local ok_socket, socket_mod = pcall(require, 'posix.sys.socket')
local bit = rawget(_G, 'bit') or rawget(_G, 'bit32')
if not bit then local ok_bit32, bit32_mod = pcall(require, 'bit32'); if ok_bit32 then bit = bit32_mod end end

if not ok_unistd or type(unistd) ~= 'table' or not ok_fcntl or type(fcntl) ~= 'table' or not ok_errno or type(errno) ~= 'table' then
  return unsupported('luaposix unistd/fcntl/errno not available')
end
if not bit then return unsupported('bit or bit32 operations not available') end

local Fd = {}
Fd.__index = Fd
local next_generation = 0

local EAGAIN = errno.EAGAIN
local EWOULDBLOCK = errno.EWOULDBLOCK or EAGAIN

local function errno_msg(prefix, err, eno)
  if err and err ~= '' then return err end
  if eno then return tostring(prefix) .. ' (errno ' .. tostring(eno) .. ')' end
  return tostring(prefix)
end

local function set_nonblocking_fd(fd, value)
  local flags, err, eno = fcntl.fcntl(fd, fcntl.F_GETFL)
  if flags == nil then return nil, errno_msg('fcntl(F_GETFL)', err, eno), eno end
  local on = fcntl.O_NONBLOCK or 0
  local new_flags = value ~= false and bit.bor(flags, on) or bit.band(flags, bit.bnot(on))
  local ok, err2, eno2 = fcntl.fcntl(fd, fcntl.F_SETFL, new_flags)
  if ok == nil then return nil, errno_msg('fcntl(F_SETFL)', err2, eno2), eno2 end
  return true
end

local function fd_read(self, max)
  max = tonumber(max) or 4096
  if max <= 0 then return '' end
  local s, err, eno = unistd.read(self.fd, max)
  if s == nil then
    if eno == EAGAIN or eno == EWOULDBLOCK then return nil, 'would_block', eno end
    return nil, errno_msg('read failed', err, eno), eno
  end
  if s == '' then return nil, Errors.EOF end
  return s
end

local function fd_write(self, bytes)
  if type(bytes) ~= 'string' then error('fd write expects bytes', 2) end
  if #bytes == 0 then return 0 end
  local n, err, eno = unistd.write(self.fd, bytes)
  if n == nil then
    if eno == EAGAIN or eno == EWOULDBLOCK then return nil, 'would_block', eno end
    return nil, errno_msg('write failed', err, eno), eno
  end
  return n
end

local function fd_shutdown_read(self, _reason)
  if ok_socket and type(socket_mod) == 'table' and type(socket_mod.shutdown) == 'function' then pcall(function() socket_mod.shutdown(self.fd, socket_mod.SHUT_RD or 0) end) end
  return true
end

local function fd_shutdown_write(self, _reason)
  if ok_socket and type(socket_mod) == 'table' and type(socket_mod.shutdown) == 'function' then pcall(function() socket_mod.shutdown(self.fd, socket_mod.SHUT_WR or 1) end) end
  return true
end

local function fd_close(self, _reason)
  if self._closed then return true end
  self._closed = true
  local ok, err, eno = unistd.close(self.fd)
  if ok == nil then return nil, errno_msg('close failed', err, eno), eno end
  return true
end

function Fd.is_supported()
  return type(unistd.read) == 'function' and type(unistd.write) == 'function' and type(unistd.close) == 'function' and type(unistd.pipe) == 'function'
end

function Fd.support_reason()
  if Fd.is_supported() then return nil end
  return 'required luaposix fd functions unavailable'
end

function Fd.wrap(fd, opts)
  opts = opts or {}
  fd = assert(tonumber(fd), 'fd must be numeric')
  next_generation = next_generation + 1
  local key = opts.key or { family = 'numeric-fd', fd = fd, generation = next_generation }
  local h = Handle.new {
    name = opts.name or ('posix-fd-' .. tostring(fd)),
    key = key,
    handle = fd,
    host = opts.host,
    read = function(self, max) return fd_read(self, max) end,
    write = function(self, bytes) return fd_write(self, bytes) end,
    shutdown_read = function(self, reason) return fd_shutdown_read(self, reason) end,
    shutdown_write = function(self, reason) return fd_shutdown_write(self, reason) end,
    close = function(self, reason) return fd_close(self, reason) end,
    set_nonblocking = function(_self, value) return set_nonblocking_fd(fd, value ~= false) end,
  }
  h.family = 'numeric-fd'
  h.fd = fd; h.raw_fd = fd; h.generation = next_generation
  if opts.nonblocking ~= false then h:set_nonblocking(true) end
  return h
end

Fd.new = Fd.wrap

function Fd.pipe(opts)
  opts = opts or {}
  local rd, wr, err, eno = unistd.pipe()
  if not rd then return nil, nil, errno_msg('pipe failed', err, eno), eno end
  local r = Fd.wrap(rd, { host = opts.host, name = opts.name and (opts.name .. ':read') or nil, nonblocking = opts.nonblocking })
  local w = Fd.wrap(wr, { host = opts.host, name = opts.name and (opts.name .. ':write') or nil, nonblocking = opts.nonblocking })
  return r, w
end

return Fd
