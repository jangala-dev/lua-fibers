-- Linux FFI helpers used by optional host smoke tests.

local M = {}

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then
  M.available = false
  M.reason = 'ffi module not available'
  return M
end

ffi.cdef([[
  int pipe(int pipefd[2]);
  long write(int fd, const void *buf, unsigned long count);
  long read(int fd, void *buf, unsigned long count);
  int open(const char *pathname, int flags, ...);
  int close(int fd);
]])

local C = ffi.C
local toint = ffi.tonumber or tonumber

local O_RDONLY = 0

M.available = true
M.ffi = ffi
M.C = C

local function close_fd(fd)
  if fd and fd >= 0 then
    pcall(function()
      C.close(fd)
    end)
  end
end

function M.close_fd(fd)
  return close_fd(fd)
end

function M.make_pipe(assert_eq)
  local fds = ffi.new('int[2]')
  local rc = toint(C.pipe(fds))
  if assert_eq then
    assert_eq(rc, 0, 'pipe() should succeed')
  elseif rc ~= 0 then
    error('pipe() failed', 2)
  end
  local rfd, wfd = toint(fds[0]), toint(fds[1])
  local closed = false
  return {
    read_key = rfd,
    write_key = wfd,
    write_byte = function(_ch)
      local buf = ffi.new('unsigned char[1]', { 120 })
      local n = toint(C.write(wfd, buf, 1))
      if n == 1 then
        return true
      end
      return nil, 'write returned ' .. tostring(n)
    end,
    close = function()
      if closed then
        return
      end
      closed = true
      close_fd(rfd)
      close_fd(wfd)
    end,
  }
end

function M.make_regular_file(assert_truthy)
  local path = os.tmpname()
  local fh, ferr = io.open(path, 'wb')
  if assert_truthy then
    assert_truthy(fh, 'io.open temp file failed: ' .. tostring(ferr))
  elseif not fh then
    error('io.open temp file failed: ' .. tostring(ferr), 2)
  end
  fh:write('x')
  fh:close()

  local fd = toint(C.open(path, O_RDONLY))
  os.remove(path)
  if assert_truthy then
    assert_truthy(fd and fd >= 0, 'open regular file should succeed')
  elseif not fd or fd < 0 then
    error('open regular file failed', 2)
  end
  local closed = false
  return {
    read_key = fd,
    close = function()
      if closed then
        return
      end
      closed = true
      close_fd(fd)
    end,
  }
end

return M
