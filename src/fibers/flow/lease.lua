-- Flow byte lease handles for the scalar-state-machine Flow.

local Lease = {}
Lease.__index = Lease

function Lease.new(flow, id, owner, bytes, opts)
  opts = opts or {}
  return setmetatable({
    flow = flow,
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
function Lease:length()
  return self._length or #(self._bytes or '')
end
function Lease:inspect()
  return {
    id = self.id,
    bytes = self:bytes(),
    length = self:length(),
    owner = self.owner,
    flow = self.flow,
  }
end
function Lease:ack_op(n)
  return self.flow:_ack_lease_op(self, n)
end
function Lease:release_op()
  return self.flow:_return_lease_op(self)
end
function Lease:fail_op(err)
  return self.flow:_fail_lease_op(self, err)
end

return Lease
