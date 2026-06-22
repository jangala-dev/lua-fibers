-- Flow byte lease handles.
--
-- A Lease is a committed temporary ownership of retained bytes.  The reservoir
-- remains the resource of record; lease methods are convenience wrappers over
-- reservoir options.

local Lease = {}
Lease.__index = Lease

function Lease.new(reservoir, id, owner, bytes, opts)
  opts = opts or {}
  if type(id) ~= 'string' then error('Flow lease id must be a string', 2) end
  if type(bytes or '') ~= 'string' then error('Flow lease bytes must be a string', 2) end
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

function Lease.is(x) return getmetatable(x) == Lease or type(x) == 'table' and x._fibers_flow_lease == true end
function Lease:bytes_value() return self._bytes or '' end
function Lease:bytes() return self._bytes or '' end
function Lease:length_value() return self._length or #(self._bytes or '') end
function Lease:length() return self._length or #(self._bytes or '') end
function Lease:owner_value() return self.owner end
function Lease:inspect() return { id = self.id, bytes = self._bytes or '', length = self:length(), owner = self.owner, reservoir = self.reservoir } end
function Lease:ack_op(n) return self.reservoir:ack_lease_op(self, n) end
function Lease:return_op() return self.reservoir:return_lease_op(self) end
function Lease:fail_op(err) return self.reservoir:fail_lease_op(self, err) end
function Lease:remaining_op() return self.reservoir:lease_existing_op(self.owner) end
function Lease:empty_op() return self.reservoir:leases_empty_op() end

return Lease
