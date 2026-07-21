-- Authoritative location algebras and trusted result/query semantics.

local M = {}

M.ABSENT = setmetatable({}, {
  __tostring = function()
    return '<absent>'
  end,
})

local function copy_operation(op)
  return { op = op.op, key = op.key, value = op.value, policy = op.policy }
end

local function copy_operations(ops)
  local out = {}
  for i = 1, #(ops or {}) do
    out[i] = copy_operation(ops[i])
  end
  return out
end

local function clone_machine(patch)
  local steps = {}
  for i = 1, #(patch.steps or {}) do
    local step = patch.steps[i]
    steps[i] = { serial = step.serial, value = step.value }
  end
  return { kind = 'machine', steps = steps }
end

local function clone_log(patch)
  return { kind = patch.kind, ops = copy_operations(patch.ops) }
end

local function clone_map_value(location, value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = location.clone_value and location.clone_value(item) or item
  end
  return out
end

local function merge_steps(left, right)
  local out, i, j = {}, 1, 1
  left, right = left or {}, right or {}
  while i <= #left and j <= #right do
    local take_left = left[i].serial <= right[j].serial
    local step = take_left and left[i] or right[j]
    out[#out + 1] = { serial = step.serial, value = step.value }
    if take_left then
      i = i + 1
    else
      j = j + 1
    end
  end
  while i <= #left do
    out[#out + 1] = { serial = left[i].serial, value = left[i].value }
    i = i + 1
  end
  while j <= #right do
    out[#out + 1] = { serial = right[j].serial, value = right[j].value }
    j = j + 1
  end
  return out
end

local function filter_operations(patch, direction)
  local ops = {}
  for i = 1, #(patch.ops or {}) do
    local op = patch.ops[i]
    local up = op.op == 'put'
    local down = op.op == 'remove' or op.op == 'take'
    if (direction == 'up' and up) or (direction == 'down' and down) then
      ops[#ops + 1] = copy_operation(op)
    end
  end
  return #ops > 0 and { kind = patch.kind, ops = ops } or nil
end

local function log_supplies(patch)
  local out = {}
  for i = 1, #(patch.ops or {}) do
    local op = patch.ops[i].op
    if op == 'put' then
      out.up = true
    elseif op == 'remove' or op == 'take' then
      out.down = true
    else
      out.any = true
    end
  end
  return out
end

local function assign(trail, target, key, value)
  if trail then
    trail:set(target, key, value)
  else
    target[key] = value
  end
end

local function push(trail, target, value)
  if trail then
    trail:push(target, value)
  else
    target[#target + 1] = value
  end
end

local Replace = { name = 'replace' }
function Replace.clone(patch)
  return { kind = 'replace', value = patch.value }
end
function Replace.apply(_, _, patch)
  return patch.value
end
function Replace.stage(summary, patch, trail)
  if not summary then
    return Replace.clone(patch)
  end
  assign(trail, summary, 'value', patch.value)
  return summary
end
function Replace.join(_, left, right)
  if left.value ~= right.value then
    return nil, 'replace-conflict'
  end
  return Replace.clone(left)
end
function Replace.constraint(_, patch)
  return Replace.clone(patch)
end
function Replace.supplies()
  return { any = true }
end

local Add = { name = 'add' }
function Add.clone(patch)
  return { kind = 'add', delta = patch.delta }
end
function Add.apply(_, value, patch)
  return value + patch.delta
end
function Add.stage(summary, patch, trail)
  if not summary then
    return Add.clone(patch)
  end
  assign(trail, summary, 'delta', summary.delta + patch.delta)
  return summary
end
function Add.join(_, left, right)
  return { kind = 'add', delta = left.delta + right.delta }
end
function Add.constraint(_, patch, orientation)
  if not orientation then
    return Add.clone(patch)
  end
  local direction = orientation == 'up' and 'down' or 'up'
  local matches = direction == 'up' and patch.delta > 0 or direction == 'down' and patch.delta < 0
  return matches and Add.clone(patch) or nil
end
function Add.supplies(patch)
  if patch.delta > 0 then
    return { up = true }
  end
  if patch.delta < 0 then
    return { down = true }
  end
  return {}
end

local Machine = { name = 'machine' }
Machine.clone = clone_machine
function Machine.apply(_, value, patch)
  local steps = patch.steps or {}
  if #steps == 0 then
    return value
  end
  return steps[#steps].value
end
function Machine.stage(summary, patch, trail)
  if not summary then
    return Machine.clone(patch)
  end
  local last, first = summary.steps[#summary.steps], patch.steps and patch.steps[1]
  if last and first and last.serial >= first.serial then
    error('machine steps must be staged in increasing serial order', 3)
  end
  for i = 1, #(patch.steps or {}) do
    local step = patch.steps[i]
    push(trail, summary.steps, { serial = step.serial, value = step.value })
  end
  return summary
end
function Machine.join(_, left, right)
  return { kind = 'machine', steps = merge_steps(left.steps, right.steps) }
end
function Machine.constraint(_, patch)
  return Machine.clone(patch)
end
function Machine.supplies()
  return { any = true }
end

local Presence = { name = 'presence' }
Presence.clone = clone_log
function Presence.apply(_, value, patch)
  for i = 1, #(patch.ops or {}) do
    local op = patch.ops[i]
    if op.op == 'put' then
      value = op.value
    elseif op.op == 'remove' or op.op == 'take' then
      value = M.ABSENT
    else
      error('unknown presence operation: ' .. tostring(op.op), 3)
    end
  end
  return value
end
function Presence.stage(summary, patch, trail)
  if not summary then
    return Presence.clone(patch)
  end
  for i = 1, #(patch.ops or {}) do
    push(trail, summary.ops, copy_operation(patch.ops[i]))
  end
  return summary
end
function Presence.join(_, left, right)
  if #(left.ops or {}) ~= 1 or #(right.ops or {}) ~= 1 then
    return nil, 'presence-complex-parallel-conflict'
  end
  local a, b = left.ops[1], right.ops[1]
  if a.op == 'put' and b.op == 'put' then
    if a.value ~= b.value then
      return nil, 'presence-put-conflict'
    end
    return { kind = 'presence', ops = { { op = 'put', value = a.value } } }
  end
  if a.op == 'put' and b.op == 'take' then
    return { kind = 'presence', ops = { copy_operation(a), { op = 'take' } } }
  end
  if a.op == 'take' and b.op == 'put' then
    return { kind = 'presence', ops = { copy_operation(b), { op = 'take' } } }
  end
  if a.op == 'remove' and b.op == 'remove' then
    return { kind = 'presence', ops = { { op = 'remove' } } }
  end
  return nil, 'presence-parallel-conflict'
end
function Presence.constraint(_, patch, orientation)
  if not orientation then
    return Presence.clone(patch)
  end
  return filter_operations(patch, orientation == 'up' and 'down' or 'up')
end
Presence.supplies = log_supplies

local function merge_map_operation(location, left, right, composition, key)
  if left.op == 'put' and right.op == 'put' then
    if location.put_equal and left.value == right.value then
      return { copy_operation(left) }
    end
    if
      (composition == 'interacting' or composition == 'external')
      and left.policy == 'overwrite'
      and right.policy == 'overwrite'
    then
      return { copy_operation(right) }
    end
    return nil, 'finite-map-put-conflict'
  end
  if (left.op == 'put' and right.op == 'take') or (left.op == 'take' and right.op == 'put') then
    local put = left.op == 'put' and left or right
    return { copy_operation(put), { op = 'take', key = key } }
  end
  if left.op == 'remove' and right.op == 'remove' and location.remove_idempotent then
    return { copy_operation(left) }
  end
  return nil, 'finite-map-parallel-conflict'
end

local FiniteMap = { name = 'finite_map' }
FiniteMap.clone = clone_log
function FiniteMap.apply(location, value, patch)
  local out = clone_map_value(location, value)
  for i = 1, #(patch.ops or {}) do
    local op = patch.ops[i]
    if op.op == 'put' then
      out[op.key] = location.clone_value and location.clone_value(op.value) or op.value
    elseif op.op == 'remove' or op.op == 'take' then
      out[op.key] = nil
    else
      error('unknown finite-map operation: ' .. tostring(op.op), 3)
    end
  end
  return out
end
function FiniteMap.stage(summary, patch, trail)
  if not summary then
    return FiniteMap.clone(patch)
  end
  for i = 1, #(patch.ops or {}) do
    push(trail, summary.ops, copy_operation(patch.ops[i]))
  end
  return summary
end
function FiniteMap.join(location, left, right, composition)
  local a, b = left.ops or {}, right.ops or {}
  if #a == 1 and #b == 1 then
    if a[1].key ~= b[1].key then
      return { kind = 'finite_map', ops = { copy_operation(a[1]), copy_operation(b[1]) } }
    end
    local ops, err = merge_map_operation(location, a[1], b[1], composition, a[1].key)
    return ops and { kind = 'finite_map', ops = ops } or nil, err
  end
  local by_left, by_right, keys = {}, {}, {}
  local function index(src, dst)
    for i = 1, #src do
      local op = src[i]
      local row = dst[op.key]
      if not row then
        row = {}
        dst[op.key] = row
        keys[op.key] = true
      end
      row[#row + 1] = op
    end
  end
  index(a, by_left)
  index(b, by_right)
  local out = {}
  local function append(values)
    for i = 1, #(values or {}) do
      out[#out + 1] = copy_operation(values[i])
    end
  end
  for key in pairs(keys) do
    local x, y = by_left[key], by_right[key]
    if not x then
      append(y)
    elseif not y then
      append(x)
    elseif #x == 1 and #y == 1 then
      local merged, err = merge_map_operation(location, x[1], y[1], composition, key)
      if not merged then
        return nil, err
      end
      append(merged)
    else
      return nil, 'finite-map-complex-parallel-conflict'
    end
  end
  return { kind = 'finite_map', ops = out }
end
function FiniteMap.constraint(_, patch, orientation)
  if not orientation then
    return FiniteMap.clone(patch)
  end
  return filter_operations(patch, orientation == 'up' and 'down' or 'up')
end
FiniteMap.supplies = log_supplies

local function key_operation(op, value_key)
  return table.concat({
    tostring(op.op or ''),
    value_key(op.key),
    value_key(op.value),
    tostring(op.policy or ''),
  }, ':')
end

function Replace.fingerprint(patch, mix, row)
  return mix(mix(row, Replace.name), patch.value)
end
function Replace.key(patch, value_key)
  return 'replace,' .. value_key(patch.value)
end

function Add.fingerprint(patch, mix, row)
  return mix(mix(row, Add.name), patch.delta)
end
function Add.key(patch, value_key)
  return 'add,' .. value_key(patch.delta)
end

function Machine.fingerprint(patch, mix, row)
  row = mix(mix(row, Machine.name), #(patch.steps or {}))
  local steps = patch.steps or {}
  if #steps > 0 then
    row = mix(row, steps[1].serial)
    row = mix(row, steps[#steps].serial)
    row = mix(row, steps[#steps].value)
  end
  return row
end
function Machine.key(patch, value_key)
  local parts = { Machine.name }
  for i = 1, #(patch.steps or {}) do
    local step = patch.steps[i]
    parts[#parts + 1] = tostring(step.serial or '') .. '=' .. value_key(step.value)
  end
  return table.concat(parts, ',')
end
function Machine.serialise(patch, relation, out)
  for i = 1, #(patch.steps or {}) do
    local step = patch.steps[i]
    out[#out + 1] = { serial = step.serial, value = step.value, relation = relation }
  end
end
function Machine.change(serial, value)
  return { kind = Machine.name, steps = { { serial = serial, value = value } } }
end

local function log_fingerprint(name, patch, mix, row)
  row = mix(mix(row, name), #(patch.ops or {}))
  local ops = patch.ops or {}
  if #ops > 0 then
    local last = ops[#ops]
    row = mix(row, last.op)
    row = mix(row, last.key)
    row = mix(row, last.value)
  end
  return row
end

local function log_key(name, patch, value_key)
  local parts = { name }
  for i = 1, #(patch.ops or {}) do
    parts[#parts + 1] = key_operation(patch.ops[i], value_key)
  end
  return table.concat(parts, ',')
end

function Presence.fingerprint(patch, mix, row)
  return log_fingerprint(Presence.name, patch, mix, row)
end
function Presence.key(patch, value_key)
  return log_key(Presence.name, patch, value_key)
end
function FiniteMap.fingerprint(patch, mix, row)
  return log_fingerprint(FiniteMap.name, patch, mix, row)
end
function FiniteMap.key(patch, value_key)
  return log_key(FiniteMap.name, patch, value_key)
end

local BY_NAME = {
  replace = Replace,
  add = Add,
  machine = Machine,
  presence = Presence,
  finite_map = FiniteMap,
}

function M.get(value)
  if type(value) == 'table' and value.apply and value.stage and value.join then
    return value
  end
  if type(value) == 'table' and value.algebra then
    return value.algebra
  end
  local algebra = BY_NAME[value]
  if not algebra then
    error('unknown location algebra: ' .. tostring(value), 3)
  end
  return algebra
end

function M.clone(patch)
  return patch and M.get(patch.kind).clone(patch) or nil
end

function M.apply(location, value, patch)
  return M.get(location).apply(location, value, patch)
end

function M.stage(location, summary, patch, trail)
  local algebra = M.get(location)
  if patch.kind ~= algebra.name then
    error(algebra.name .. ' location requires ' .. algebra.name .. ' patch', 3)
  end
  return algebra.stage(summary, patch, trail)
end

function M.join(location, left, right, composition)
  if not left then
    return M.clone(right)
  end
  if not right then
    return M.clone(left)
  end
  return M.get(location).join(location, left, right, composition)
end

function M.constraint(location, patch, orientation)
  return M.get(location).constraint(location, patch, orientation)
end

function M.supplies(location, patch)
  return M.get(location).supplies(patch)
end

function M.fingerprint(location, summary, mix, row)
  return M.get(location).fingerprint(summary, mix, row)
end

function M.key(location, summary, value_key)
  return M.get(location).key(summary, value_key)
end

function M.serialise(location, summary, relation, out)
  local serialise = M.get(location).serialise
  if serialise then
    serialise(summary, relation, out)
  end
  return out
end

function M.machine_change(location, serial, value)
  local change = M.get(location).change
  if not change then
    error('location algebra does not accept machine changes', 3)
  end
  return change(serial, value)
end

return M
