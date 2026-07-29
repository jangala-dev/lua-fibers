local Facility = require('fibers.resource.authoring')
local perform = require('fibers.perform')

local Rendezvous = {}
Rendezvous.__index = Rendezvous
local Kind = Facility.kind('rendezvous')

function Rendezvous.new(name)
  local self = Facility.identity(setmetatable({}, Rendezvous), Kind, name)
  self._get_op = Facility.static(self, Kind, 'exchange', { role = 'get' })
  self._put_descriptor = Facility.descriptor(self, Kind, 'exchange', {
    role = 'put',
    bind = 'value',
  })
  return self
end
function Rendezvous:get_op()
  return self._get_op
end

function Rendezvous:get()
  return perform(self:get_op())
end
function Rendezvous:put_op(value)
  return Facility.occurrence(self._put_descriptor, value)
end

function Rendezvous:put(value)
  return perform(self:put_op(value))
end
Rendezvous.Kind = Kind
return Rendezvous
