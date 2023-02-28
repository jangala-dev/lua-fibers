local fileno = require "posix".fileno -- could be org.conman.fsys instead but I don't have it installed
local cqueues = require "cqueues"

local cq = cqueues.new()

local cnt = 0
local notdone = true
cq:wrap(function()
    local f = assert(io.popen("/home/daurnimator/spc-b.lua","r"))
    local pollable = {
        pollfd = fileno(f);
        events = "r";
    }
    while cqueues.poll(pollable) do -- yield the current thread until we have data
        local data = f:read("*l") -- this isn't necessarily correct; if a whole line isn't ready to read it will block
        if data == nil then
            -- f:read returns nil on EOF
            f:close()
            break
        end
        print(data)
        print(cnt)
    end
    notdone = false
end)
cq:wrap(function()
    while notdone do
        cnt = cnt + 1
        cqueues.poll() -- yield the current thread
    end
end)
assert(cq:loop())
