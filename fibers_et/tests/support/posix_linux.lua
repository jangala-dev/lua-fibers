-- luaposix helpers used by optional host smoke tests.

local M = {}

local ok_unistd, unistd = pcall(require, 'posix.unistd')
local ok_fcntl, fcntl = pcall(require, 'posix.fcntl')
local ok_stat, stat = pcall(require, 'posix.sys.stat')

if not ok_unistd or type(unistd) ~= 'table' or not ok_fcntl or type(fcntl) ~= 'table' then
  M.available = false
  M.reason = 'luaposix unistd/fcntl not available'
  return M
end

M.available = true

local function close_fd(fd)
  if fd then
    pcall(function()
      unistd.close(fd)
    end)
  end
end

function M.close_fd(fd)
  return close_fd(fd)
end

function M.make_pipe(assert_truthy)
  local rd, wr, err, eno = unistd.pipe()
  if assert_truthy then
    assert_truthy(rd and wr, 'posix.pipe should succeed: ' .. tostring(err or eno))
  elseif not rd or not wr then
    error('posix.pipe failed: ' .. tostring(err or eno), 2)
  end
  local closed = false
  return {
    read_key = rd,
    write_key = wr,
    write_byte = function(ch)
      local n, werr, weno = unistd.write(wr, ch or 'x')
      if n == 1 then
        return true
      end
      return nil, 'write returned ' .. tostring(n) .. ' ' .. tostring(werr or weno)
    end,
    close = function()
      if closed then
        return
      end
      closed = true
      close_fd(rd)
      close_fd(wr)
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
  local mode = stat and stat.S_IRUSR or 256
  local fd, err, eno = fcntl.open(path, fcntl.O_RDONLY, mode)
  os.remove(path)
  if assert_truthy then
    assert_truthy(fd, 'posix.open regular file should succeed: ' .. tostring(err or eno))
  elseif not fd then
    error('posix.open regular file failed: ' .. tostring(err or eno), 2)
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
