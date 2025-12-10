package.path = "../src/?.lua;" .. package.path
package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'

local sep = '-'

local modules = {
    { 'utils',    'bytes' },
    { 'utils',    'bytes_stress' },
    { 'io',   'file' },
    { 'io',   'mem' },
    { 'io',   'stream' },
    { 'io',   'socket' },
    { 'io',   'exec_backend' },
    { 'io',   'exec' },
    { 'timer' },
    { 'alarm' },
    { 'sched' },
    { 'runtime' },
    { 'channel' },
    { 'cond' },
    { 'sleep' },
    { 'waitgroup' },
    { 'scope' },
}

for _, j in ipairs(modules) do
    local test_file_name = "test".."_"..table.concat(j, sep)..".lua"
    dofile(test_file_name)
end

print('all tests passed!')
