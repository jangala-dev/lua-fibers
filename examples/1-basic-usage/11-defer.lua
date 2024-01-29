package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require 'fibers.fiber'

local defscope = fiber.defscope
local defer = fiber.defer

-- Define some resource type for testing.
-- In practice, this is a resource we acquire and
-- release (e.g. a file, database handle, Win32 handle, etc.).
local Resource = {}; do
	Resource.__index = Resource
	function Resource:__tostring() return self.name end
	function Resource.open(name)
		local self = setmetatable({name=name,is_open=true}, Resource)
		print("open", name)
		return self
	end
	function Resource:close() print("close", self.name) end
	function Resource:foo()   print("hello", self.name) end
end

fiber.spawn(function ()
    local test3 = defscope(function()
        local d = Resource.open('D')
        defer(d.close, d)
        d:foo()
        print("as far as we go")
        error("oops")
    end)

    local test2 = defscope(function()
        defer(function(e) print("a defer called", e) end, "Frank")
        local c = Resource.open('C')
        defer(c.close, c)
        test3()
    end)

    local test1 = defscope(function()
        defer(fiber.stop)
        local a = Resource.open('A')
        defer(a.close, a)
        local b = Resource.open('B')
        defer(b.close, b)
        print(pcall(test2))
        print("doing another thing")
    end)

    test1()
end)

fiber.main()