-- Metamethod-free process-local identity for exact search keys and cheap hashes.
--
-- Non-scalar values receive weakly held numeric identities.  Exact keys never
-- call tostring on tables, functions, userdata or threads, so user-defined
-- __tostring methods cannot collapse distinct speculative states or run during
-- proof search.

local M = {}

local object_ids = setmetatable({}, { __mode = 'k' })
local next_object_id = 0

function M.object_id(value)
  local id = object_ids[value]
  if not id then
    next_object_id = next_object_id + 1
    id = next_object_id
    object_ids[value] = id
  end
  return id
end

function M.key(value)
  local kind = type(value)
  if kind == 'nil' then
    return 'z'
  elseif kind == 'boolean' then
    return value and 'b1' or 'b0'
  elseif kind == 'number' then
    if value ~= value then
      return 'n:nan'
    end
    if value == 0 then
      value = 0 -- Treat positive and negative zero as the same Lua value.
    end
    return 'n:' .. string.format('%.17g', value)
  elseif kind == 'string' then
    return 's:' .. #value .. ':' .. value
  end
  return kind .. '#' .. M.object_id(value)
end

function M.less(left, right)
  return M.key(left) < M.key(right)
end

function M.hash(value, modulus)
  local kind = type(value)
  if kind == 'nil' then
    return 0
  elseif kind == 'boolean' then
    return value and 1 or 2
  elseif kind == 'number' then
    if value ~= value then
      return 3
    end
    return math.floor(math.abs(value) * 1009 + 0.5) % modulus
  elseif kind == 'string' then
    local hash = #value + 17
    for i = 1, #value do
      hash = (hash * 131 + value:byte(i)) % modulus
    end
    return hash
  end
  return M.object_id(value) % modulus
end

return M
