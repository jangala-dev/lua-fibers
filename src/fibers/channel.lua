-- Small channel facade over the base communication/storage primitives.
--
-- Channel.new(0) returns a Rendezvous; Channel.new(n > 0) returns a bounded
-- Queue of capacity n.  It deliberately introduces no new resource law.

local Queue = require('fibers.queue')
local Rendezvous = require('fibers.atoms.rendezvous')

local Channel = {}

local function normalise_capacity(capacity)
  if capacity == nil then
    return 0
  end
  if type(capacity) ~= 'number' or capacity < 0 or capacity ~= math.floor(capacity) then
    error('channel capacity must be a non-negative integer', 3)
  end
  return capacity
end

function Channel.new(capacity, opts)
  if type(capacity) == 'table' then
    opts = capacity
    capacity = opts.capacity
  end
  opts = opts or {}
  capacity = normalise_capacity(capacity)
  local name = opts.name
  if capacity == 0 then
    return opts.rendezvous or Rendezvous.new(name)
  end
  return opts.queue or Queue.new({ capacity = capacity, name = name })
end

return Channel
