local Completion = require('fibers.resource.completion')
local Direct = require('fibers.internal.direct')

local Latch = {}
Latch.__index = Latch
setmetatable(Latch, { __index = Completion })

function Latch.new()
  return setmetatable(Completion.new(), Latch)
end

function Latch:set_op(value)
  return self:publish_success_op(value):map(function(first) return first == true end)
end

function Latch:get_op() return self:success_op() end
function Latch:is_set_op() return self:is_terminal_op() end

Direct.install(Latch, { 'set', 'get', 'is_set' })
return Latch
