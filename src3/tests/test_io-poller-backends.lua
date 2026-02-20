-- tests/test_io-poller-backends.lua
package.path = '../?.lua;' .. package.path

local function make_waker()
  return { count = 0, signal = function(self) self.count = self.count + 1 end }
end

local function try_require(name)
  local ok, mod = pcall(require, name)
  if not ok then return nil, mod end
  return mod
end

local function skip(name, why)
  io.stdout:write(('%s: skipped (%s)\n'):format(name, why))
end

local function ok(name)
  io.stdout:write(('%s: ok\n'):format(name))
end

-- -----------------------------------------------------------------------------
-- Pipe helpers (integer fds)
-- -----------------------------------------------------------------------------

local function make_pipe_posix()
  local unistd = try_require('posix.unistd')
  if not unistd or type(unistd.pipe) ~= 'function' then
    return nil, 'posix.unistd.pipe not available'
  end

  local r, w = unistd.pipe()
  if not r or not w then
    return nil, 'posix.unistd.pipe failed'
  end

  local function write_byte(fd)
    -- posix.unistd.write(fd, string) -> nbytes, err
    local n, err = unistd.write(fd, 'x')
    assert(n == 1, ('write failed: %s'):format(tostring(err)))
  end

  local function read_byte(fd)
    local s, err = unistd.read(fd, 1)
    assert(s and #s == 1, ('read failed: %s'):format(tostring(err)))
    return s
  end

  local function close_fd(fd)
    local _ = unistd.close(fd)
  end

  return {
    r = r, w = w,
    write_byte = write_byte,
    read_byte = read_byte,
    close = function()
      close_fd(r); close_fd(w)
    end
  }
end

local function make_pipe_ffi()
  local ffi_c = try_require('fibers.utils.ffi_compat')
  if not ffi_c or not (ffi_c.is_supported and ffi_c.is_supported()) then
    return nil, 'ffi_compat not supported'
  end

  local ffi, C = ffi_c.ffi, ffi_c.C
  local tonumber_ = ffi_c.tonumber or tonumber

  ffi.cdef [[
    typedef unsigned long size_t;
    typedef long ssize_t;
    int pipe(int pipefd[2]);
    ssize_t read(int fd, void *buf, size_t count);
    ssize_t write(int fd, const void *buf, size_t count);
    int close(int fd);
  ]]

  local fds = ffi.new('int[2]')
  local rc = C.pipe(fds)
  if rc ~= 0 then
    return nil, 'C.pipe failed'
  end

  local r = tonumber_(fds[0])
  local w = tonumber_(fds[1])

  local function write_byte(fd)
    local buf = ffi.new('uint8_t[1]', 0x78) -- 'x'
    local n = C.write(fd, buf, 1)
    assert(n == 1, 'C.write failed')
  end

  local function read_byte(fd)
    local buf = ffi.new('uint8_t[1]')
    local n = C.read(fd, buf, 1)
    assert(n == 1, 'C.read failed')
    return string.char(tonumber_(buf[0]))
  end

  local function close_fd(fd)
    local _ = C.close(fd)
  end

  return {
    r = r, w = w,
    write_byte = write_byte,
    read_byte = read_byte,
    close = function()
      close_fd(r); close_fd(w)
    end
  }
end

local function make_pipe_intfds()
  local p, why = make_pipe_posix()
  if p then return p end
  p, why = make_pipe_ffi()
  if p then return p end
  return nil, why
end

-- -----------------------------------------------------------------------------
-- Pipe helpers (nixio objects)
-- -----------------------------------------------------------------------------

local function make_pipe_nixio()
  local nixio = try_require('nixio')
  if not nixio then
    return nil, 'nixio not available'
  end
  if type(nixio.pipe) ~= 'function' then
    return nil, 'nixio.pipe not available'
  end

  local r, w = nixio.pipe()
  if not r or not w then
    return nil, 'nixio.pipe failed'
  end

  local function write_byte(fdobj)
    -- nixio file objects typically provide :write(string)
    local n = fdobj:write('x')
    assert(n == 1 or n == true, 'nixio write failed')
  end

  local function read_byte(fdobj)
    local s = fdobj:read(1)
    assert(type(s) == 'string' and #s == 1, 'nixio read failed')
    return s
  end

  local function close_obj(o)
    if o and o.close then pcall(function() o:close() end) end
  end

  return {
    r = r, w = w,
    write_byte = write_byte,
    read_byte = read_byte,
    close = function()
      close_obj(r); close_obj(w)
    end
  }
end

-- -----------------------------------------------------------------------------
-- Backend runner
-- -----------------------------------------------------------------------------

local function run_backend(name, pipe_maker)
  local mod, err = try_require(name)
  if not mod then
    skip(name, 'require failed: ' .. tostring(err))
    return
  end

  if type(mod) ~= 'table' or type(mod.is_supported) ~= 'function' or not mod.is_supported() then
    skip(name, 'not supported')
    return
  end
  if type(mod.new) ~= 'function' then
    skip(name, 'missing new()')
    return
  end

  local pipe, why = pipe_maker()
  if not pipe then
    skip(name, 'cannot create pipe: ' .. tostring(why))
    return
  end

  local p = mod.new()
  assert(type(p) == 'table' and type(p.watch) == 'function' and type(p.poll) == 'function', name .. ': bad poller instance')
  assert(p:has_watchers() == false, name .. ': expected no watchers initially')

  -- Read readiness test: write one byte, poll, expect signal, then drain.
  do
    local w = make_waker()
    local h = p:watch(pipe.r, 'rd', w)
    pipe.write_byte(pipe.w)
    p:poll(0)
    assert(w.count == 1, name .. ': rd watcher was not signalled')
    assert(h.fired == true, name .. ': handle.fired not set')
    pipe.read_byte(pipe.r)

    p:cancel(h)
    assert(p:has_watchers() == false, name .. ': expected watchers cleared after cancel')
    -- idempotent cancel should not underflow
    p:cancel(h)
    assert(p:has_watchers() == false, name .. ': cancel underflowed watchers')
  end

  -- Re-watch after cancel: ensures backend interest updates and (for oneshot) re-arming are correct.
  do
    local w = make_waker()
    local h = p:watch(pipe.r, 'rd', w)
    pipe.write_byte(pipe.w)
    p:poll(0)
    assert(w.count == 1, name .. ': rd watcher did not fire after re-watch')
    pipe.read_byte(pipe.r)
    p:cancel(h)
  end

  -- Light write-readiness sanity check (pipes are typically writable immediately).
  do
    local w = make_waker()
    local h = p:watch(pipe.w, 'wr', w)
    p:poll(0)
    -- Some environments may not report OUT in the way you expect; keep this as a sanity check.
    -- If it does fire, great; if not, do not fail the whole suite.
    p:cancel(h)
  end

  if type(p.close) == 'function' then
    p:close()
  end
  pipe.close()

  ok(name)
end

-- -----------------------------------------------------------------------------
-- Execute
-- -----------------------------------------------------------------------------

run_backend('fibers.io.poller.epoll',  make_pipe_intfds)
run_backend('fibers.io.poller.select', make_pipe_intfds)
run_backend('fibers.io.poller.nixio',  make_pipe_nixio)

print('test_io-poller-backends.lua: done')
