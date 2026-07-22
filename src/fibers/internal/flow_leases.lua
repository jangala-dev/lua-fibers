-- Internal data and capacity lease handles used by Flow.

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

function Lease.is(value)
  return getmetatable(value) == Lease or type(value) == 'table' and value._fibers_flow_lease == true
end
function Lease:bytes()
  return self._bytes or ''
end
function Lease:length()
  return self._length or #(self._bytes or '')
end
function Lease:inspect()
  return { id = self.id, bytes = self:bytes(), length = self:length(), owner = self.owner, flow = self.flow }
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

local SpaceLease = {}
SpaceLease.__index = SpaceLease

function SpaceLease.new(flow, id, owner, capacity, opts)
  opts = opts or {}
  return setmetatable({
    flow = flow,
    id = id,
    owner = owner,
    _capacity = capacity or 0,
    meta = opts.meta,
    _fibers_flow_space_lease = true,
  }, SpaceLease)
end

function SpaceLease.is(value)
  return getmetatable(value) == SpaceLease
    or type(value) == 'table' and value._fibers_flow_space_lease == true
end
function SpaceLease:capacity()
  return self._capacity or 0
end
function SpaceLease:inspect()
  return { id = self.id, capacity = self:capacity(), owner = self.owner, flow = self.flow, meta = self.meta }
end
function SpaceLease:commit_op(bytes)
  return self.flow:_commit_space_op(self, bytes)
end
function SpaceLease:release_op()
  return self.flow:_release_space_op(self)
end
function SpaceLease:fail_op(err)
  return self.flow:_fail_space_op(self, err)
end

return { Lease = Lease, SpaceLease = SpaceLease }
