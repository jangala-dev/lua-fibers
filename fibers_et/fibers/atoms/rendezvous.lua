local Op = require('fibers.atoms.op')
local Program = require('fibers.kernel.ir')
local Rendezvous = {}; Rendezvous.__index = Rendezvous
local Kind = { name = 'rendezvous' }; local next_id = 0
function Rendezvous.new(name)
  next_id = next_id + 1
  return setmetatable({ name = name or ('rendezvous-' .. tostring(next_id)), _fibers_id = 'rendezvous-' .. tostring(next_id), _fibers_kind = Kind }, Rendezvous)
end
function Rendezvous:get_op() return Op._resource(self, Kind, Program.exchange(self, 'get')) end
function Rendezvous:put_op(value) return Op._resource(self, Kind, Program.exchange(self, 'put', value)) end
Rendezvous.Kind = Kind
return Rendezvous
