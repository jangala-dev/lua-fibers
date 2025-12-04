-- tests/test_exec_backend.lua
--
-- Backend-level tests for fibers.io.exec_backend.
-- Uses the real backend but does not involve fibers or the scheduler.

print('testing: fibers.io.exec_backend')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local proc_backend = require 'fibers.io.exec_backend'
local sc           = require 'fibers.utils.syscall'
local stdlib       = require 'posix.stdlib'

local function read_all(fd)
  local chunks = {}
  while true do
    local s, err, errno = sc.read(fd, 4096)
    assert(s ~= nil or err, "read returned nil without error")
    if s == nil then
      error(("read failed: %s (errno %s)"):format(tostring(err), tostring(errno)))
    end
    if #s == 0 then
      break
    end
    chunks[#chunks + 1] = s
  end
  return table.concat(chunks)
end

-- Block in a simple loop on nonblock_wait until the child is finished.
-- New backend contract: nonblock_wait() → done:boolean, code, signal, err
local function wait_blocking(backend)
  while true do
    local exited, code, sig, err = backend:nonblock_wait()
    assert(err == nil, "nonblock_wait error: " .. tostring(err))
    if exited then
      return code, sig
    end
  end
end

----------------------------------------------------------------------
-- Test 1: simple exit code
----------------------------------------------------------------------

local function test_simple_exit()
  local spec = {
    argv      = { "sh", "-c", "exit 7" },
    cwd       = nil,
    env       = nil,
    stdin_fd  = nil,
    stdout_fd = nil,
    stderr_fd = nil,
    flags     = nil,
  }

  local backend, err = proc_backend.start(spec)
  assert(backend, "start failed: " .. tostring(err))

  local code, sig = wait_blocking(backend)
  assert(code == 7,
    ("expected exit code 7, got %s"):format(tostring(code)))
  assert(sig == nil, "expected no terminating signal")
end

----------------------------------------------------------------------
-- Test 2: inherited environment
----------------------------------------------------------------------

local function test_env_inherit()
  -- Ensure a parent variable is set.
  assert(stdlib.setenv("PROC_BACKEND_TEST", "parent_inherit"))

  -- Pipe to capture stdout.
  local rd, wr = assert(sc.pipe())

  local spec = {
    argv      = { "sh", "-c", 'printf "%s\n" "$PROC_BACKEND_TEST"' },
    cwd       = nil,
    env       = nil,     -- inherit environment
    stdin_fd  = nil,
    stdout_fd = wr,      -- child stdout -> pipe write end
    stderr_fd = wr,      -- send stderr the same way for simplicity
    flags     = nil,
  }

  local backend, err = proc_backend.start(spec)
  assert(backend, "start failed: " .. tostring(err))

  -- Parent no longer needs write end.
  assert(sc.close(wr))

  local out = read_all(rd)
  assert(sc.close(rd))

  local code, sig = wait_blocking(backend)
  assert(code == 0, "expected shell to exit 0")
  assert(sig == nil, "expected no terminating signal")

  assert(out == "parent_inherit\n",
    ("expected 'parent_inherit', got %q"):format(out))
end

----------------------------------------------------------------------
-- Test 3: environment override (env table)
----------------------------------------------------------------------

local function test_env_override()
  -- Parent value that should be hidden/overridden.
  assert(stdlib.setenv("PROC_BACKEND_TEST", "parent_value"))

  local rd, wr = assert(sc.pipe())

  local spec = {
    argv      = { "sh", "-c", 'printf "%s\n" "$PROC_BACKEND_TEST"' },
    cwd       = nil,
    env       = { PROC_BACKEND_TEST = "child_value" }, -- override
    stdin_fd  = nil,
    stdout_fd = wr,
    stderr_fd = wr,
    flags     = nil,
  }

  local backend, err = proc_backend.start(spec)
  assert(backend, "start failed: " .. tostring(err))

  assert(sc.close(wr))

  local out = read_all(rd)
  assert(sc.close(rd))

  local code, sig = wait_blocking(backend)
  assert(code == 0, "expected shell to exit 0")
  assert(sig == nil, "expected no terminating signal")

  assert(out == "child_value\n",
    ("expected 'child_value', got %q"):format(out))
end

----------------------------------------------------------------------
-- Run tests
----------------------------------------------------------------------

local function main()
  test_simple_exit()
  test_env_inherit()
  test_env_override()
  io.stdout:write("proc_backend tests passed\n")
end

main()
