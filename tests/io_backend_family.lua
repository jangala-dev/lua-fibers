-- tests/io_backend_family.lua
--
-- Test helper for forcing a single fibers.io backend family in a fresh Lua
-- process. This deliberately prevents mixed fd/poller/exec backend selection.
-- It must be required before any fibers.io selector or higher-level fibers.io
-- module is loaded.

local M = {}

local families = {
	ffi = {
		fd     = 'fibers.io.fd_backend.ffi',
		poller = 'fibers.io.poller.epoll',
		exec   = 'fibers.io.exec_backend.pidfd',
		disable = {
			'fibers.io.fd_backend.posix',
			'fibers.io.fd_backend.nixio',
			'fibers.io.poller.select',
			'fibers.io.poller.nixio',
			'fibers.io.exec_backend.sigchld',
			'fibers.io.exec_backend.posix_reaper',
			'fibers.io.exec_backend.nixio',
		},
	},
	posix = {
		fd     = 'fibers.io.fd_backend.posix',
		poller = 'fibers.io.poller.select',
		exec   = function ()
			if rawget(_G, 'jit') then
				return 'fibers.io.exec_backend.posix_reaper'
			end
			return 'fibers.io.exec_backend.sigchld'
		end,
		disable = {
			'fibers.io.fd_backend.ffi',
			'fibers.io.fd_backend.nixio',
			'fibers.io.poller.epoll',
			'fibers.io.poller.nixio',
			'fibers.io.exec_backend.pidfd',
			'fibers.io.exec_backend.nixio',
		},
	},
	nixio = {
		fd     = 'fibers.io.fd_backend.nixio',
		poller = 'fibers.io.poller.nixio',
		exec   = 'fibers.io.exec_backend.nixio',
		disable = {
			'fibers.io.fd_backend.ffi',
			'fibers.io.fd_backend.posix',
			'fibers.io.poller.epoll',
			'fibers.io.poller.select',
			'fibers.io.exec_backend.pidfd',
			'fibers.io.exec_backend.sigchld',
			'fibers.io.exec_backend.posix_reaper',
		},
	},
}

local selectors = {
	'fibers.io.fd_backend',
	'fibers.io.poller',
	'fibers.io.exec_backend',
	'fibers.io.file',
	'fibers.io.socket',
	'fibers.io.stream',
	'fibers.io.exec',
}

local function already_loaded(name)
	return package.loaded[name] ~= nil
end

local function fail_if_io_loaded()
	for _, name in ipairs(selectors) do
		assert(not already_loaded(name),
			('cannot force backend family after %s has already been loaded'):format(name))
	end
end

local function disabled_loader(name)
	return function()
		error(('backend module %s disabled by io_backend_family test gate'):format(name), 0)
	end
end

function M.expected(family)
	local spec = families[family]
	assert(spec, ('unknown backend family %q'):format(tostring(family)))
	return spec
end

local function expected_exec(spec)
	if type(spec.exec) == 'function' then
		return spec.exec()
	end
	return spec.exec
end

function M.force(family)
	local spec = M.expected(family)
	fail_if_io_loaded()
	for _, name in ipairs(spec.disable) do
		package.loaded[name] = nil
		package.preload[name] = disabled_loader(name)
	end
	_G.__FIBERS_TEST_IO_BACKEND_FAMILY = family
	return spec
end

local function assert_supported(name)
	local ok, mod = pcall(require, name)
	assert(ok, ('failed to require %s: %s'):format(name, tostring(mod)))
	assert(type(mod) == 'table', ('%s did not return a table'):format(name))
	assert(type(mod.is_supported) == 'function', ('%s has no is_supported()'):format(name))
	assert(mod.is_supported(), ('%s is not supported in this runtime'):format(name))
	return mod
end

function M.assert_selected(family)
	local spec = M.expected(family)
	assert_supported(spec.fd)
	assert_supported(spec.poller)
	local exec_name = expected_exec(spec)
	assert_supported(exec_name)

	local fd_backend = require 'fibers.io.fd_backend'
	local poller     = require 'fibers.io.poller'
	local exec_be    = require 'fibers.io.exec_backend'

	assert(fd_backend == package.loaded[spec.fd],
		('fd_backend selector did not choose %s'):format(spec.fd))
	assert(poller == package.loaded[spec.poller],
		('poller selector did not choose %s'):format(spec.poller))
	assert(exec_be == package.loaded[exec_name],
		('exec_backend selector did not choose %s'):format(exec_name))

	for _, name in ipairs(spec.disable) do
		-- The selector deliberately probes earlier candidates with pcall(require, name).
		-- A disabled preload loader may therefore leave package.loaded[name] as
		-- false/nil depending on the Lua implementation.  What must not happen is
		-- successful loading of a backend module table.
		assert(type(package.loaded[name]) ~= 'table',
			('disabled backend was unexpectedly loaded: %s'):format(name))
	end
end

return M
