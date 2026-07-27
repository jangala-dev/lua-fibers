-- Channel facade over rendezvous and FIFO resources.
--
-- Capacity zero selects rendezvous, finite positive capacity selects a bounded
-- FIFO, and math.huge selects an unbounded FIFO.

local FIFO = require('fibers.resource.fifo')
local Rendezvous = require('fibers.resource.rendezvous')

local Channel = {}

function Channel.new(capacity, name)
  capacity = capacity == nil and 0 or capacity
  return capacity == 0 and Rendezvous.new(name) or FIFO.new(capacity, name)
end

return Channel
