local Op = require('fibers.op')
local Rendezvous = {}
Rendezvous.__index = Rendezvous
local Kind = { name = 'rendezvous' }
local next_id = 0
function Rendezvous.new(name)
  next_id = next_id + 1
  local self = setmetatable({
    name = name or ('rendezvous-' .. tostring(next_id)),
    _fibers_id = 'rendezvous-' .. tostring(next_id),
    _fibers_kind = Kind,
  }, Rendezvous)
  self._get_op = Op._compact_resource(self, Kind, 'exchange', { role = 'get' })
  self._put_descriptor = Op._compact_descriptor(self, Kind, 'exchange', {
    role = 'put',
    payload_field = 'value',
  })
  return self
end
function Rendezvous:get_op()
  return self._get_op
end
function Rendezvous:put_op(value)
  return Op._compact_occurrence(self._put_descriptor, value)
end
Rendezvous.Kind = Kind
return Rendezvous
