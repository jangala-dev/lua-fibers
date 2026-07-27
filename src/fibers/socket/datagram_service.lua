-- Bounded read/write service policy for DatagramSocket drivers.
--
-- The driver still waits with unordered choice because readiness and queue
-- arrivals are temporal events.  Once one side wakes the driver, this policy
-- transactionally checks whether the currently preferred side is also
-- available.  If so it selects that side; otherwise it services the wake-up.
-- A configurable quantum bounds consecutive progress while both sides remain
-- continuously serviceable.

local Op = require('fibers.op')

local Service = {}
Service.__index = Service

local function read_event_op(handle)
  return handle:read_ready_op():map(function()
    return { kind = 'read' }
  end)
end

local function write_event_op(handle, sends, pending)
  if pending then
    return handle:write_ready_op():map(function()
      return { kind = 'write', record = pending }
    end)
  end
  return sends:next_op():map(function(record)
    return { kind = 'write', record = record }
  end)
end

function Service.new(quantum)
  quantum = tonumber(quantum or 1)
  if not quantum or quantum < 1 or quantum ~= math.floor(quantum) then
    error('datagram service quantum must be a positive integer', 2)
  end
  return setmetatable({
    quantum = quantum,
    preferred = 'read',
    remaining = quantum,
  }, Service)
end

function Service:next_op(handle, sends, pending)
  local read_op = read_event_op(handle)
  local write_op = write_event_op(handle, sends, pending)

  local footprint = Op.dependencies(read_op, write_op)
  return Op.choice(read_op, write_op):and_then(function(event)
    local held = pending
    if event.kind == 'write' then
      held = event.record
    end

    if event.kind == self.preferred then
      return Op.always(event, held)
    end

    local preferred_op
    if self.preferred == 'read' then
      preferred_op = read_op
    else
      preferred_op = write_event_op(handle, sends, held)
    end

    return preferred_op
      :map(function(preferred_event)
        local next_pending = held
        if preferred_event.kind == 'write' then
          next_pending = preferred_event.record
        end
        return preferred_event, next_pending
      end)
      :or_else(Op.always(event, held))
  end, footprint)
end

function Service:progress(kind)
  if kind ~= self.preferred then
    return
  end

  self.remaining = self.remaining - 1
  if self.remaining > 0 then
    return
  end

  self.preferred = self.preferred == 'read' and 'write' or 'read'
  self.remaining = self.quantum
end

return Service
