package.path = "../?.lua;" .. package.path

local package_name = 'fibers.utils'

local modules = {
    'buffer',
}

for _, j in ipairs(modules) do
    require(package_name.."."..j).selftest()
end

local package_name = 'stream'

local modules = {
    'stream',
    'stream.file',
    'stream.mem',
    'stream.compat',
    'stream.socket',
}

for _, j in ipairs(modules) do
    require(package_name.."."..j).selftest()
end

local package_name = 'fibers'

local modules = {
    'timer', 
    'sched', 
    'fiber',
    'channel',
    'sleep',
    'epoller',
    'cond',
    'file',
    'queue',
}

for _, j in ipairs(modules) do
    require(package_name.."."..j).selftest()
end

print('all tests passed!')