local Facility = require('fibers.resource.authoring')
local Direct = require('fibers.internal.direct')

local Rendezvous = {}
Rendezvous.__index = Rendezvous
local Kind = Facility.kind('rendezvous')

function Rendezvous.new()
  local self = Facility.identity(setmetatable({}, Rendezvous), Kind)
  self._get_op = Facility.op(Facility.rule.exchange({ resource = self, role = 'get' }))
  self._put_spec = Facility.rule.exchange({ resource = self, role = 'put' })
  return self
end
function Rendezvous:get_op()
  return self._get_op
end

function Rendezvous:put_op(value)
  return Facility.bind(self._put_spec, value)
end

Direct.install(Rendezvous, { 'get', 'put' })

Rendezvous.Kind = Kind
return Rendezvous
