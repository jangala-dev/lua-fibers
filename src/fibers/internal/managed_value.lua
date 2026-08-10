-- Public managed-value semantics for Cell and Machine.
--
-- Managed values are finite value trees: nil, booleans, numbers, strings and
-- plain Lua tables whose keys are scalar managed values and whose values are
-- recursively managed values. Tables may not carry metatables, cycles or
-- shared references. Every boundary crossing copies the tree, so authoritative
-- managed state never shares a mutable table with ordinary Lua code.

local ManagedValue = {}

local function scalar_equal(left, right)
  if left == right then return true end
  return type(left) == 'number' and type(right) == 'number' and left ~= left and right ~= right
end

local function key_path(path, key)
  local kind = type(key)
  if kind == 'string' and key:match('^[A-Za-z_][A-Za-z0-9_]*$') then
    return path .. '.' .. key
  end
  if kind == 'string' then return path .. '[' .. string.format('%q', key) .. ']' end
  if kind == 'number' or kind == 'boolean' then return path .. '[' .. tostring(key) .. ']' end
  return path .. '[<' .. kind .. ' key>]'
end

local function fail(label, detail, path, extra, level)
  local lines = {
    'fibers: invalid managed value',
    '',
    tostring(label or 'managed value') .. ' ' .. detail .. ' at:',
    '    ' .. path,
  }
  if extra then
    lines[#lines + 1] = ''
    lines[#lines + 1] = extra
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Managed values may contain only nil, boolean, number, string, and plain finite tables'
  lines[#lines + 1] = 'recursively containing managed values. Tables may not have metatables, cycles, shared'
  lines[#lines + 1] = 'references, or identity-bearing keys or values.'
  local message = table.concat(lines, '\n')
  error(message, level or 3)
end

local function valid_key(key, label, path, level)
  local kind = type(key)
  if kind == 'string' or kind == 'boolean' then return end
  if kind == 'number' and key == key then return end
  fail(label, 'contains a forbidden ' .. kind .. ' key', path, nil, level)
end

local function capture_tree(value, label, path, seen, active, level)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' then return value end
  if kind ~= 'table' then
    fail(label, 'contains a forbidden ' .. kind .. ' value', path, nil, level)
  end
  if getmetatable(value) ~= nil then
    fail(label, 'contains a table with a metatable', path, nil, level)
  end

  local first = seen[value]
  if first then
    if active[value] then
      fail(label, 'contains a cycle', path, 'The same table is already active at:\n    ' .. first, level)
    end
    fail(
      label,
      'contains a shared table reference',
      path,
      'The same table first occurs at:\n    ' .. first .. '\n\nManaged values are value trees, not object graphs.',
      level
    )
  end

  seen[value], active[value] = path, true
  local out = {}
  for key, item in pairs(value) do
    local item_path = key_path(path, key)
    valid_key(key, label, item_path, level)
    out[key] = capture_tree(item, label, item_path, seen, active, level)
  end
  active[value] = nil
  return out
end

function ManagedValue.capture(value, label, level)
  return capture_tree(value, label or 'managed value', '$', {}, {}, (level or 2) + 1)
end

local function copy_tree(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy_tree(item) end
  return out
end

function ManagedValue.expose(value)
  return copy_tree(value)
end

function ManagedValue.equal(left, right)
  if scalar_equal(left, right) then return true end
  if type(left) ~= 'table' or type(right) ~= 'table' then return false end

  local left_count, right_count = 0, 0
  for key, value in pairs(left) do
    left_count = left_count + 1
    local other = right[key]
    if other == nil or not ManagedValue.equal(value, other) then return false end
  end
  for _ in pairs(right) do right_count = right_count + 1 end
  return left_count == right_count
end

return ManagedValue
