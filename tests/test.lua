package.path = "../?.lua;" .. package.path

local sep = '-'

local modules = {
    {'utils','buffer'},
    {'stream'},
    {'stream','file'},
    {'stream','mem'},
    {'stream','compat'},
    {'stream','socket'},
    {'timer'},
    {'sched'},
    {'fiber'},
    {'channel'},
    {'queue'},
    {'cond'},
    {'sleep'},
    {'epoll'},
    {'file'},
}

for _, j in ipairs(modules) do
    local test_file_name = "test".."_"..table.concat(j, sep)..".lua"
    dofile(test_file_name)
end

print('all tests passed!')