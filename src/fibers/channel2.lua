-- fibers/channel2_teach.lua
local op = require 'fibers.op2'
local rv = require 'fibers.rendezvous'

local Channel = {}
Channel.__index = Channel

local function new()
	local core = rv.make()
	return setmetatable({ _core = core }, Channel)
end

function Channel:put_op(val) return self._core.send_op(val) end
function Channel:get_op()    return self._core.recv_op() end
function Channel:put(val)    return op.perform(self:put_op(val)) end
function Channel:get()       return op.perform(self:get_op()) end

return { new = new }
