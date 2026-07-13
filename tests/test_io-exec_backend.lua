-- tests/test_exec_backend.lua
--
-- Backend-level tests for fibers.io.exec_backend.
-- Uses the real backend but does not involve fibers or the scheduler.

print('testing: fibers.io.exec_backend')

-- look one level up
package.path = '../src/?.lua;' .. package.path

local proc_backend = require 'fibers.io.exec_backend'
local stdlib       = require 'posix.stdlib'

----------------------------------------------------------------------
-- ExecStreamConfig helpers
----------------------------------------------------------------------

local function inherit_stream()
	return { mode = 'inherit' }
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Block in a simple loop on the backend's poll operation until the
-- child is finished.
-- exec_backend.core wires ops.poll(state) -> done:boolean, code|nil, signal|nil, err|nil
local function wait_blocking(backend)
	while true do
		local done, code, sig, err = backend._ops.poll(backend._state)
		assert(err == nil, 'poll error: ' .. tostring(err))
		if done then
			return code, sig
		end
		-- Busy wait is acceptable here: tests are short-lived and single-process.
	end
end

----------------------------------------------------------------------
-- Test 1: simple exit code
----------------------------------------------------------------------

local function test_simple_exit()
	local spec = {
		argv   = { 'sh', '-c', 'exit 7' },
		cwd    = nil,
		env    = nil,
		flags  = nil,
		stdin  = inherit_stream(),
		stdout = inherit_stream(),
		stderr = inherit_stream(),
	}

	-- start() now returns a ProcHandle: { backend = ExecBackend, stdin, stdout, stderr }
	local handle, err = proc_backend.start(spec)
	assert(handle, 'start failed: ' .. tostring(err))

	local backend = assert(handle.backend, 'no backend in handle')

	local code, sig = wait_blocking(backend)
	assert(code == 7,
		('expected exit code 7, got %s'):format(tostring(code)))
	assert(sig == nil, 'expected no terminating signal')
end

----------------------------------------------------------------------
-- Test 2: inherited environment
----------------------------------------------------------------------

local function test_env_inherit()
	-- Ensure a parent variable is set.
	assert(stdlib.setenv('PROC_BACKEND_TEST', 'parent_inherit'))

	-- Shell script checks inherited value and exits 0 only on match.
	local script = [[
    if [ "$PROC_BACKEND_TEST" = "parent_inherit" ]; then
      exit 0
    else
      exit 42
    fi
  ]]

	local spec = {
		argv   = { 'sh', '-c', script },
		cwd    = nil,
		env    = nil, -- inherit environment
		flags  = nil,
		stdin  = inherit_stream(),
		stdout = inherit_stream(),
		stderr = inherit_stream(),
	}

	local handle, err = proc_backend.start(spec)
	assert(handle, 'start failed: ' .. tostring(err))
	local backend = assert(handle.backend, 'no backend in handle')

	local code, sig = wait_blocking(backend)
	assert(sig == nil, 'expected no terminating signal')
	assert(code == 0,
		('expected exit code 0 from env inherit test, got %s'):format(tostring(code)))
end

----------------------------------------------------------------------
-- Test 3: environment override (env table)
----------------------------------------------------------------------

local function test_env_override()
	-- Parent value that should be overridden in the child.
	assert(stdlib.setenv('PROC_BACKEND_TEST', 'parent_value'))

	local script = [[
    if [ "$PROC_BACKEND_TEST" = "child_value" ]; then
      exit 0
    else
      exit 43
    fi
  ]]

	local spec = {
		argv   = { 'sh', '-c', script },
		cwd    = nil,
		env    = { PROC_BACKEND_TEST = 'child_value' }, -- override
		flags  = nil,
		stdin  = inherit_stream(),
		stdout = inherit_stream(),
		stderr = inherit_stream(),
	}

	local handle, err = proc_backend.start(spec)
	assert(handle, 'start failed: ' .. tostring(err))
	local backend = assert(handle.backend, 'no backend in handle')

	local code, sig = wait_blocking(backend)
	assert(sig == nil, 'expected no terminating signal')
	assert(code == 0,
		('expected exit code 0 from env override test, got %s'):format(tostring(code)))
end

----------------------------------------------------------------------
-- Run tests
----------------------------------------------------------------------

local function main()
	test_simple_exit()
	test_env_inherit()
	test_env_override()
	io.stdout:write('proc_backend tests passed\n')
end

main()
