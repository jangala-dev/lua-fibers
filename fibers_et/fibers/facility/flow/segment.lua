-- Pure byte segment values for Flow.
--
-- A Segment is retained bytes with a stable algebraic name.  It deliberately
-- knows nothing about EOF, readiness, capacity, leases or endpoints.

local Segment = {}
Segment.__index = Segment

function Segment.new(bytes, opts)
  opts = opts or {}
  if type(bytes) ~= 'string' then error('Segment bytes must be a string', 2) end
  return setmetatable({ bytes = bytes, length = #bytes, meta = opts.meta }, Segment)
end

function Segment.is(x) return getmetatable(x) == Segment or type(x) == 'table' and x._fibers_flow_segment == true end
function Segment.bytes(s) return s and s.bytes or '' end
function Segment.length(s) return s and (s.length or #(s.bytes or '')) or 0 end
function Segment.empty(s) return Segment.length(s) == 0 end
function Segment.prefix(s, n) return Segment.new(string.sub(Segment.bytes(s), 1, n or Segment.length(s)), { meta = s and s.meta }) end
function Segment.drop(s, n) return Segment.new(string.sub(Segment.bytes(s), (n or 0) + 1), { meta = s and s.meta }) end
function Segment.split(s, n) return Segment.prefix(s, n), Segment.drop(s, n) end

function Segment.concat(list)
  local parts = {}
  for i = 1, #(list or {}) do parts[#parts + 1] = Segment.bytes(list[i]) end
  return Segment.new(table.concat(parts))
end

function Segment.coalesce(list, limit)
  limit = limit or 8192
  local out = {}
  for i = 1, #(list or {}) do
    local bytes = Segment.bytes(list[i])
    local last = out[#out]
    if last and #last.bytes + #bytes <= limit then
      out[#out] = Segment.new(last.bytes .. bytes, { meta = last.meta })
    elseif bytes ~= '' then
      out[#out + 1] = Segment.new(bytes)
    end
  end
  return out
end

function Segment.inspect(s) return { bytes = Segment.bytes(s), length = Segment.length(s), meta = s and s.meta } end

return Segment
