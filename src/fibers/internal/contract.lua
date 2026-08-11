-- Exact, non-coercing checks for public and trusted-extension boundaries.

local Contract = {}

local function check(ok, value, label, message, level)
  if not ok then error((label or 'value') .. ' ' .. message, level or 3) end
  return value
end

local function finite(value)
  return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function Contract.non_empty_string(v, l, n)
  return check(type(v) == 'string' and v ~= '', v, l, 'must be a non-empty string', n)
end

function Contract.finite_number(v, l, n)
  return check(finite(v), v, l, 'must be a finite number', n)
end

function Contract.non_negative_number(v, l, n)
  return check(finite(v) and v >= 0, v, l, 'must be a finite non-negative number', n)
end

function Contract.integer(v, l, n)
  return check(finite(v) and v == math.floor(v), v, l, 'must be an integer', n)
end

function Contract.non_negative_integer(v, l, n)
  return check(finite(v) and v >= 0 and v == math.floor(v), v, l, 'must be a non-negative integer', n)
end

function Contract.positive_integer(v, l, n)
  return check(finite(v) and v >= 1 and v == math.floor(v), v, l, 'must be a positive integer', n)
end

function Contract.boolean(v, l, n)
  return check(type(v) == 'boolean', v, l, 'must be boolean', n)
end

function Contract.table(v, l, n)
  return check(type(v) == 'table', v, l, 'must be a table', n)
end

function Contract.copy_table(v, l, n)
  if v == nil then return {} end
  Contract.table(v, l or 'table', n or 3)
  local out = {}
  for key, item in pairs(v) do out[key] = item end
  return out
end

function Contract.func(v, l, n)
  return check(type(v) == 'function', v, l, 'must be a function', n)
end

function Contract.optional_boolean(v, l, n)
  if v ~= nil then return Contract.boolean(v, l, n) end
end

function Contract.optional_function(v, l, n)
  if v ~= nil then return Contract.func(v, l, n) end
end


function Contract.dense(v, l, n, item)
  Contract.table(v, l, (n or 2) + 1)
  local count = #v
  for key in pairs(v) do
    if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) or key > count then
      error((l or 'value') .. ' must be a dense array', n or 3)
    end
  end
  if item then for i = 1, count do item(v[i], (l or 'value') .. '[' .. i .. ']', (n or 2) + 1) end end
  return v
end

function Contract.range(validate, minimum, maximum)
  return function(v, l, n)
    validate(v, l, (n or 2) + 1)
    if v < minimum or v > maximum then
      error((l or 'value') .. ' must be from ' .. minimum .. ' to ' .. maximum, n or 3)
    end
    return v
  end
end

-- A closed record. Rules are validators or true for an unconstrained field.
-- Nil is omission; required fields are asserted by the owning constructor.
function Contract.record(value, schema, label, level)
  if value == nil then value = {} end
  if type(value) ~= 'table' then
    error((label or 'options') .. ' must be a table or nil', level or 3)
  end
  for key, item in pairs(value) do
    local rule = schema[key]
    if rule == nil then error((label or 'options') .. ' does not accept ' .. tostring(key), level or 3) end
    if rule ~= true then rule(item, (label or 'options') .. '.' .. tostring(key), (level or 2) + 1) end
  end
  return value
end

Contract.options = Contract.record

return Contract
