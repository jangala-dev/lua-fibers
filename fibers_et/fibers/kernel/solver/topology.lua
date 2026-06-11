local Topology = {}

function Topology.internal_allowed(a, b)
  return a.origin ~= b.origin
end

return Topology
