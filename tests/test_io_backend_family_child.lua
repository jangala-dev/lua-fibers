-- tests/test_io_backend_family_child.lua
--
-- Runs the existing I/O tests under one forced backend family. This script is
-- launched by test_io-backend_families.lua in a fresh Lua process so selector
-- state cannot leak between families.

package.path = '../src/?.lua;' .. package.path
package.path = './?.lua;' .. package.path
package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'

local family
for i = 1, #arg do
	if arg[i] == '--family' then
		family = arg[i + 1]
	end
end

assert(family, 'usage: lua test_io_backend_family_child.lua --family <ffi|posix|nixio>')

local gate = require 'io_backend_family'
gate.force(family)
gate.assert_selected(family)

print(('testing: fibers.io backend family: %s'):format(family))

-- These are the existing tests that are materially affected by fd_backend,
-- poller and exec_backend selection. They are intentionally re-run once per
-- family in separate processes.
local tests = {
	'test_io-file.lua',
	'test_io-socket.lua',
	'test_io-upload_stress.lua',
	'test_io-exec_backend.lua',
	'test_io-exec.lua',
}

for _, file in ipairs(tests) do
	dofile(file)
end

print(('backend family %s: all selected I/O tests passed'):format(family))
