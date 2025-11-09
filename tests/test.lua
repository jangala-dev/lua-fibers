package.path = "../src/?.lua;" .. package.path
package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'

local sep = '-'

local modules = {
    { 'utils',    'fixed_buffer' },
    { 'stream' },
    { 'stream',   'file' },
    { 'stream',   'mem' },
    { 'stream',   'compat' },
    { 'stream',   'socket' },
    { 'timer' },
    { 'sched' },
    { 'fiber' },
    { 'channel' },
    { 'queue' },
    { 'cond' },
    { 'sleep' },
    { 'epoll' },
    { 'pollio' },
    -- { 'exec' },
    { 'waitgroup' },
    { 'alarm' },
    { 'context' },
    { 'scope' },
}

for _, j in ipairs(modules) do
    local test_file_name = "test".."_"..table.concat(j, sep)..".lua"
    dofile(test_file_name)
end

print('all tests passed!')
