-- Shared numeric-fd HostHandle implementation for LuaJIT FFI and cffi.
--
-- Provider-specific modules are responsible for loading their ffi object and
-- bit operations explicitly.  This module deliberately does not auto-select an
-- ffi provider.

local Handle = require('fibers.host.handle')
local Errors = require('fibers.flow.errors')
local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')

local Common = {}

local function make_unsupported(prefix, reason)
  return Provider.unsupported(prefix, reason, { 'new', 'wrap', 'pipe' })
end

local function make_tonumber(ffi)
  local toint = rawget(ffi, 'tonumber') or tonumber
  return function(v)
    local n = toint(v)
    if n == nil then
      n = tonumber(v)
    end
    return n
  end
end

function Common.new(opts)
  opts = opts or {}
  local name = opts.name or 'fd_ffi'
  local prefix = opts.error_prefix or ('fibers.host.' .. name)
  local ffi = assert(opts.ffi, 'ffi provider required')
  local bit = assert(opts.bit, 'bit operations required')
  local C = opts.C or ffi.C
  local tonumber_c = opts.tonumber_c or make_tonumber(ffi)

  local ok_cdef, cdef_err = pcall(function()
    ffi.cdef([[
      typedef long ssize_t;
      typedef unsigned long size_t;
      ssize_t read(int fd, void *buf, size_t count);
      ssize_t write(int fd, const void *buf, size_t count);
      int close(int fd);
      int shutdown(int sockfd, int how);
      int pipe(int pipefd[2]);
      int fcntl(int fd, int cmd, ...);
      char *strerror(int errnum);
    ]])
  end)
  if not ok_cdef then
    -- cdefs may already be present in some providers.  Probe below decides
    -- whether the backend is usable.
    opts._cdef_err = cdef_err
  end

  local EINTR = 4
  local EAGAIN = 11
  local EWOULDBLOCK = 11
  local F_GETFD = 1
  local F_SETFD = 2
  local F_GETFL = 3
  local F_SETFL = 4
  local FD_CLOEXEC = 1
  local O_NONBLOCK = 2048
  local SHUT_RD = 0
  local SHUT_WR = 1

  local function errno()
    return ffi.errno()
  end

  local function is_null(ptr)
    if ptr == nil then
      return true
    end
    local nullptr = rawget(ffi, 'nullptr')
    return nullptr ~= nil and ptr == nullptr
  end

  local function vararg_int(value)
    if type(ffi.cast) == 'function' then
      local ok, converted = pcall(ffi.cast, 'int', value)
      if ok then
        return converted
      end
    end
    return value
  end

  local function strerror(e)
    local ok, s = pcall(function()
      return C.strerror(e)
    end)
    if not ok or is_null(s) then
      return 'errno ' .. tostring(e)
    end
    return ffi.string(s)
  end

  local function would_block(e)
    return e == EAGAIN or e == EWOULDBLOCK
  end

  local function retrying_syscall(fn)
    while true do
      local rc = tonumber_c(fn())
      if rc ~= -1 then
        return rc
      end
      local e = errno()
      if e ~= EINTR then
        return nil, e
      end
    end
  end

  local function set_cloexec_fd(fd, value)
    local flags, e = retrying_syscall(function()
      return C.fcntl(fd, F_GETFD, vararg_int(0))
    end)
    if not flags then
      return nil, HostError.system('fd', 'set_cloexec', strerror(e), nil, e), e
    end
    local new_flags
    if value ~= false then
      new_flags = bit.bor(flags, FD_CLOEXEC)
    else
      new_flags = bit.band(flags, bit.bnot(FD_CLOEXEC))
    end
    local ok, e2 = retrying_syscall(function()
      return C.fcntl(fd, F_SETFD, vararg_int(new_flags))
    end)
    if not ok then
      return nil, HostError.system('fd', 'set_cloexec', strerror(e2), nil, e2), e2
    end
    return true
  end

  local function set_nonblocking_fd(fd, value)
    local flags, e = retrying_syscall(function()
      return C.fcntl(fd, F_GETFL, vararg_int(0))
    end)
    if not flags then
      return nil, HostError.system('fd', 'set_nonblocking', strerror(e), nil, e), e
    end
    local new_flags
    if value ~= false then
      new_flags = bit.bor(flags, O_NONBLOCK)
    else
      new_flags = bit.band(flags, bit.bnot(O_NONBLOCK))
    end
    local ok, e2 = retrying_syscall(function()
      return C.fcntl(fd, F_SETFL, vararg_int(new_flags))
    end)
    if not ok then
      return nil, HostError.system('fd', 'set_nonblocking', strerror(e2), nil, e2), e2
    end
    return true
  end

  local function fd_read(self, max)
    max = tonumber(max) or 4096
    if max <= 0 then
      return ''
    end
    local buf = ffi.new('char[?]', max)
    while true do
      local n = tonumber_c(C.read(self.fd, buf, max))
      if n and n > 0 then
        return ffi.string(buf, n)
      end
      if n == 0 then
        return nil, Errors.EOF
      end
      local e = errno()
      if e == EINTR then
        -- retry
      elseif would_block(e) then
        return nil, 'would_block', e
      else
        return nil, strerror(e), e
      end
    end
  end

  local function fd_write(self, bytes)
    if type(bytes) ~= 'string' then
      error('fd write expects bytes', 2)
    end
    local len = #bytes
    if len == 0 then
      return 0
    end
    while true do
      local n = tonumber_c(C.write(self.fd, bytes, len))
      if n and n >= 0 then
        return n
      end
      local e = errno()
      if e == EINTR then
        -- retry
      elseif would_block(e) then
        return nil, 'would_block', e
      else
        return nil, strerror(e), e
      end
    end
  end

  local function fd_shutdown_read(self, _reason)
    -- shutdown is valid for sockets but not pipes/regular files.  Treat common
    -- non-socket failure as non-fatal; close() remains the definitive release.
    pcall(function()
      C.shutdown(self.fd, SHUT_RD)
    end)
    return true
  end

  local function fd_shutdown_write(self, _reason)
    pcall(function()
      C.shutdown(self.fd, SHUT_WR)
    end)
    return true
  end

  local function fd_close(self, _reason)
    if self._closed then
      return true
    end
    self._closed = true
    while true do
      local rc = tonumber_c(C.close(self.fd))
      if rc == 0 then
        return true
      end
      local e = errno()
      if e ~= EINTR then
        return nil, strerror(e), e
      end
    end
  end

  local next_generation = 0
  local Fd = {}
  Fd.__index = Fd

  function Fd.is_supported()
    local ok = pcall(function()
      return C.read, C.write, C.close, C.pipe, C.fcntl
    end)
    return ok
  end

  function Fd.support_reason()
    if Fd.is_supported() then
      return nil
    end
    return opts._cdef_err or (name .. ' C read/write/pipe/fcntl functions unavailable')
  end

  function Fd.new(fd, wrap_opts)
    wrap_opts = wrap_opts or {}
    fd = assert(tonumber(fd), 'fd must be numeric')
    next_generation = next_generation + 1
    local key = wrap_opts.key or { family = 'numeric-fd', fd = fd, generation = next_generation }
    local h = Handle.new({
      name = wrap_opts.name or (name .. '-fd-' .. tostring(fd)),
      key = key,
      handle = fd,
      host = wrap_opts.host,
      read = function(self, max)
        return fd_read(self, max)
      end,
      write = function(self, bytes)
        return fd_write(self, bytes)
      end,
      shutdown_read = function(self, reason)
        return fd_shutdown_read(self, reason)
      end,
      shutdown_write = function(self, reason)
        return fd_shutdown_write(self, reason)
      end,
      close = function(self, reason)
        return fd_close(self, reason)
      end,
      set_nonblocking = function(_self, value)
        return set_nonblocking_fd(fd, value ~= false)
      end,
    })
    h.family = 'numeric-fd'
    h.fd = fd
    h.generation = next_generation
    h.raw_fd = fd
    if wrap_opts.cloexec ~= false then
      local ok, err = set_cloexec_fd(fd, true)
      if not ok then
        h:close('set_cloexec failed')
        return nil, err
      end
    end
    if wrap_opts.nonblocking ~= false then
      local ok, err = h:set_nonblocking(true)
      if not ok then
        h:close('set_nonblocking failed')
        return nil, err
      end
    end
    return h
  end


  function Fd.pipe(pipe_opts)
    pipe_opts = pipe_opts or {}
    local fds = ffi.new('int[2]')
    local rc = tonumber_c(C.pipe(fds))
    if rc ~= 0 then
      local e = errno()
      return nil, nil, HostError.system('pipe', 'create', strerror(e), nil, e), e
    end
    local r, rerr = Fd.new(tonumber_c(fds[0]), {
      host = pipe_opts.host,
      name = pipe_opts.name and (pipe_opts.name .. ':read') or nil,
      nonblocking = pipe_opts.nonblocking,
    })
    if not r then
      pcall(function()
        C.close(tonumber_c(fds[1]))
      end)
      return nil, nil, rerr
    end
    local w, werr = Fd.new(tonumber_c(fds[1]), {
      host = pipe_opts.host,
      name = pipe_opts.name and (pipe_opts.name .. ':write') or nil,
      nonblocking = pipe_opts.nonblocking,
    })
    if not w then
      r:close('paired pipe wrap failed')
      return nil, nil, werr
    end
    r.capabilities.write = false
    r.capabilities.shutdown_write = false
    w.capabilities.read = false
    w.capabilities.shutdown_read = false
    return r, w
  end

  return Fd
end

Common.unsupported = make_unsupported
Common.make_tonumber = make_tonumber

return Common
