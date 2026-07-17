-- Flow capacity reservation handles.
--
-- A SpaceLease reserves producer-side capacity before an irreversible external
-- producer obtains bytes.  The reservation is retained by the Flow until it is
-- committed, released, failed, or the Flow is settled.

local SpaceLease = {}
SpaceLease.__index = SpaceLease

function SpaceLease.new(reservoir, id, owner, capacity, opts)
  opts = opts or {}
  return setmetatable({
    reservoir = reservoir,
    id = id,
    owner = owner,
    _capacity = capacity or 0,
    meta = opts.meta,
    _fibers_flow_space_lease = true,
  }, SpaceLease)
end

function SpaceLease.is(x)
  return getmetatable(x) == SpaceLease or type(x) == 'table' and x._fibers_flow_space_lease == true
end

function SpaceLease:capacity()
  return self._capacity or 0
end

function SpaceLease:inspect()
  return {
    id = self.id,
    capacity = self:capacity(),
    owner = self.owner,
    reservoir = self.reservoir,
    meta = self.meta,
  }
end

function SpaceLease:commit_op(bytes)
  return self.reservoir:commit_space_op(self, bytes)
end

function SpaceLease:release_op()
  return self.reservoir:release_space_op(self)
end

function SpaceLease:fail_op(err)
  return self.reservoir:fail_space_op(self, err)
end

return SpaceLease
