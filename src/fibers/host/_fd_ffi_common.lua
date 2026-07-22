-- Shared numeric-fd HostHandle implementation for LuaJIT FFI and cffi.
--
-- Provider-specific modules are responsible for loading their ffi object and
-- bit operations explicitly.  This module deliberately does not auto-select an
-- ffi provider.

local FdClass = require('fibers.host.fd_class')
local Errors = require('fibers.flow.errors')
local HostError = require('fibers.host.error')

local FfiNative = require('fibers.host.ffi_native')

local Common = {}

function Common.new(opts)
  opts = opts or {}
  local name = opts.name or 'fd_ffi'
  local prefix = opts.error_prefix or ('fibers.host.' .. name)
  local native = opts.native or FfiNative.new(opts)
  local ffi, C = native.ffi, native.C
  local tonumber_c = native.number

  local ok_cdef, cdef_err = native.cdef([[
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
  if not ok_cdef then
    -- cdefs may already be present in some providers.  Probe below decides
    -- whether the backend is usable.
    opts._cdef_err = cdef_err
  end

  local EINTR, SHUT_RD, SHUT_WR = 4, 0, 1
  local errno, strerror = native.errno, native.strerror

  local function configure(action, fn, fd, value)
    local ok, number = fn(fd, value)
    if ok then
      return true
    end
    return nil, HostError.system('fd', action, strerror(number), nil, number), number
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
      elseif native.would_block(e) then
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
      elseif native.would_block(e) then
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

  local function fd_close(self)
    if self._closed then
      return true
    end
    self._closed = true
    local ok, number = native.close_fd(self.fd)
    if ok then
      return true
    end
    return nil, strerror(number), number
  end

  local operations = {
    read = fd_read,
    write = fd_write,
    shutdown_read = fd_shutdown_read,
    shutdown_write = fd_shutdown_write,
    close = fd_close,
    set_nonblocking = function(self, value)
      return configure('set_nonblocking', native.set_nonblocking, self.fd, value)
    end,
  }

  local Fd = FdClass.define({
    family = 'numeric-fd',
    operations = operations,
    is_supported = function()
      return pcall(function()
        return C.read, C.write, C.close, C.pipe, C.fcntl
      end)
    end,
    support_reason = function()
      return opts._cdef_err or (name .. ' C read/write/pipe/fcntl functions unavailable')
    end,
    validate = function(fd)
      return assert(tonumber(fd), 'fd must be numeric')
    end,
    describe = function(fd, generation)
      return {
        name = name .. '-fd-' .. tostring(fd),
        key = { family = 'numeric-fd', fd = fd, generation = generation },
      }
    end,
    decorate = function(handle, fd)
      handle.fd, handle.raw_fd = fd, fd
    end,
    configure = function(handle, wrap_opts)
      if wrap_opts.cloexec ~= false then
        local ok, err, extra = configure('set_cloexec', native.set_cloexec, handle.fd, true)
        if not ok then
          return nil, err, extra
        end
      end
      if wrap_opts.nonblocking ~= false then
        return handle:set_nonblocking(true)
      end
      return true
    end,
    pipe = function()
      local reader, writer, number = native.pipe(false)
      if reader then
        return reader, writer
      end
      return nil, nil, HostError.system('pipe', 'create', strerror(number), nil, number), number
    end,
    close_raw = native.close_fd,
  })

  return Fd
end

return Common
