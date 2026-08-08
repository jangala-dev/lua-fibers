-- Nil-preserving value tuples shared by the operation language and evaluators.

local Values = {}
local unpack_ = table.unpack or unpack

function Values.pack(...)
  return { _fibers_pack = true, n = select('#', ...), ... }
end

function Values.unpack(values, first, last)
  return unpack_(values, first or 1, last or values.n)
end

function Values.is(value)
  return type(value) == 'table' and value._fibers_pack == true
end

function Values.equal(left, right)
  if left == right then return true end
  if type(left) ~= 'table' or type(right) ~= 'table' then return false end
  local ln, rn = left.n, right.n
  if ln ~= rn then return false end
  for i = 1, ln do
    local a, b = left[i], right[i]
    if a ~= b and not (type(a) == 'number' and type(b) == 'number' and a ~= a and b ~= b) then
      return false
    end
  end
  return true
end

return Values
