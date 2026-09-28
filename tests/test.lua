package.path = '../src/?.lua;' .. package.path
package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'

local sep = '-'

local modules = {
	{ 'utils',    'bytes' },
	{ 'utils',    'dlist' },
	{ 'utils',    'bytes_stress' },
	{ 'io',       'file' },
	{ 'io',       'mem' },
	{ 'io',       'stream' },
	{ 'io',       'socket' },
	{ 'io',       'upload_stress' },
	{ 'io',       'exec_backend' },
	{ 'io',       'exec' },
	{ 'io',       'backend_families' },
	{ 'timer' },
	{ 'alarm' },
	{ 'sched' },
	{ 'runtime' },
	{ 'channel' },
	{ 'mailbox' },
	{ 'pulse' },
	{ 'oneshot' },
	{ 'cond' },
	{ 'sleep' },
	{ 'sleep', 'timer_cancel' },
	{ 'waitgroup' },
	{ 'scope' },
}

for _, j in ipairs(modules) do
	local test_file_name = 'test' .. '_' .. table.concat(j, sep) .. '.lua'
	dofile(test_file_name)
end

print('all tests passed!')
