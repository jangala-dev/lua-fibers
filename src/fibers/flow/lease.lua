-- Flow byte lease handles for the scalar-state-machine Flow.

local Lease = {}
Lease.__index = Lease

function Lease.new(reservoir, id, owner, bytes, opts)
  opts = opts or {}
  return setmetatable({
    reservoir = reservoir,
    id = id,
    owner = owner,
    _bytes = bytes or '',
    _length = #(bytes or ''),
    meta = opts.meta,
    _fibers_flow_lease = true,
  }, Lease)
end

function Lease.is(x)
  return getmetatable(x) == Lease or type(x) == 'table' and x._fibers_flow_lease == true
end
function Lease:bytes()
  return self._bytes or ''
end
function Lease:bytes_value()
  return self:bytes()
end
function Lease:length()
  return self._length or #(self._bytes or '')
end
function Lease:length_value()
  return self:length()
end
function Lease:inspect()
  return {
    id = self.id,
    bytes = self:bytes(),
    length = self:length(),
    owner = self.owner,
    reservoir = self.reservoir,
  }
end
function Lease:ack_op(n)
  return self.reservoir:ack_lease_op(self, n)
end
function Lease:return_op()
  return self.reservoir:return_lease_op(self)
end
function Lease:fail_op(err)
  return self.reservoir:fail_lease_op(self, err)
end

return Lease
