-- Shared native context for one atomic FFI host family.

local M = {}

function M.new(opts)
  opts = opts or {}
  local ffi = assert(opts.ffi, 'ffi provider required')
  local C = opts.C or ffi.C
  local toint = opts.tonumber_c or rawget(ffi, 'tonumber') or tonumber
  local native = {
    ffi = ffi,
    C = C,
    bit = opts.bit,
  }

  function native.number(value)
    return toint(value) or tonumber(value)
  end

  function native.cdef(source)
    return pcall(ffi.cdef, source)
  end

  function native.errno()
    return ffi.errno()
  end

  function native.null(value)
    if value == nil then
      return true
    end
    local nullptr = rawget(ffi, 'nullptr')
    return nullptr ~= nil and value == nullptr
  end

  function native.strerror(number)
    local ok, value = pcall(C.strerror, number)
    if not ok or native.null(value) then
      return 'errno ' .. tostring(number)
    end
    return ffi.string(value)
  end

  function native.vararg_int(value)
    if type(ffi.cast) == 'function' then
      local ok, converted = pcall(ffi.cast, 'int', value)
      if ok then
        return converted
      end
    end
    return value
  end

  function native.retry(fn, interrupted)
    interrupted = interrupted or 4
    while true do
      local result = native.number(fn())
      if result ~= -1 then
        return result
      end
      local number = native.errno()
      if number ~= interrupted then
        return nil, number
      end
    end
  end

  native.cdef([[
      int close(int fd);
      int pipe(int pipefd[2]);
      int fcntl(int fd, int cmd, ...);
  ]])
  local bit = assert(native.bit, 'bit operations required')
  local F_GETFD, F_SETFD, F_GETFL, F_SETFL = 1, 2, 3, 4
  local FD_CLOEXEC, O_NONBLOCK = 1, 2048

  local function set_flag(fd, get_cmd, set_cmd, flag, enabled)
    local current, number = native.retry(function()
      return C.fcntl(fd, get_cmd, native.vararg_int(0))
    end)
    if current == nil then
      return nil, number
    end
    local value = enabled ~= false and bit.bor(current, flag) or bit.band(current, bit.bnot(flag))
    local ok, next_number = native.retry(function()
      return C.fcntl(fd, set_cmd, native.vararg_int(value))
    end)
    return ok ~= nil and true or nil, next_number
  end

  function native.set_cloexec(fd, enabled)
    return set_flag(fd, F_GETFD, F_SETFD, FD_CLOEXEC, enabled)
  end

  function native.set_nonblocking(fd, enabled)
    return set_flag(fd, F_GETFL, F_SETFL, O_NONBLOCK, enabled)
  end

  function native.close_fd(fd)
    if fd == nil or fd < 0 then
      return true
    end
    local ok, number = native.retry(function()
      return C.close(fd)
    end)
    return ok ~= nil and true or nil, number
  end

  function native.pipe(cloexec)
    local fds = ffi.new('int[2]')
    if native.number(C.pipe(fds)) ~= 0 then
      return nil, nil, native.errno()
    end
    local reader, writer = native.number(fds[0]), native.number(fds[1])
    if cloexec then
      local ok1, err1 = native.set_cloexec(reader, true)
      local ok2, err2 = native.set_cloexec(writer, true)
      if not ok1 or not ok2 then
        native.close_fd(reader)
        native.close_fd(writer)
        return nil, nil, err1 or err2
      end
    end
    return reader, writer
  end

  function native.would_block(number)
    return number == 11
  end

  return native
end

return M
