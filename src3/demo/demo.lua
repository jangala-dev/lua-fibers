-- demo/demo.lua

package.path = '../?.lua;' .. package.path


local runtime = require 'fibers.runtime2'
local op      = require 'fibers.op2'
local chan    = require 'fibers.channel2'

local function println(...)
	io.write(table.concat({ ... }, ' '), '\n')
end

local c1 = chan.new()
local c2 = chan.new()

runtime.spawn(function()
	println('[sender1] sending on c1')
	c1:put('A')
	println('[sender1] done')
end, 'sender1')

runtime.spawn(function()
	println('[sender2] sending on c2')
	c2:put('B')
	println('[sender2] done')
end, 'sender2')

runtime.spawn(function()
	println('[all] waiting for both c1 and c2')
	local v1, v2 = op.perform(op.all(c1:get_op(), c2:get_op()))
	println('[all] got', tostring(v1), tostring(v2))
end, 'all')

runtime.spawn(function()
	println('[sender3] sending on c1')
	c1:put('LEFT')
	println('[sender3] done')
end, 'sender3')

runtime.spawn(function()
	println('[sender4] sending on c2')
	c2:put('RIGHT')
	println('[sender4] done')
end, 'sender4')

runtime.spawn(function()
	println('[choice] waiting for first of c1/c2')
	local which, val = op.perform(op.choice(
		op.map(c1:get_op(), function (v) return 'c1', v end),
		op.map(c2:get_op(), function (v) return 'c2', v end)
	))
	println('[choice] got', which, tostring(val))

	-- For unbuffered channels, the losing sender remains blocked: drain the other.
	if which == 'c1' then
		local w = c2:get()
		println('[choice] drained other:', 'c2', tostring(w))
	else
		local w = c1:get()
		println('[choice] drained other:', 'c1', tostring(w))
	end
end, 'choice')

runtime.main()
println('[main] scheduler run queue drained')
