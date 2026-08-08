-- Authoritative location algebras and trusted result/query semantics.

local M = {}


local VALID = { up = true, down = true, any = true }

local function fail(label, message, level)
  error((label or 'supply declaration') .. ' ' .. message, (level or 1) + 1)
end

function M.normalise_supply(value, label, level)
  if value == nil then
    fail(label, 'requires an explicit supplies declaration', (level or 1) + 1)
  end

  if value == 'none' then
    return {}
  elseif value == 'up' then
    return { up = true }
  elseif value == 'down' then
    return { down = true }
  elseif value == 'any' then
    return { any = true }
  end

  if type(value) ~= 'table' then
    fail(label, 'must be none, up, down, any, or a supply set', (level or 1) + 1)
  end

  local out = {}
  for key, present in pairs(value) do
    if not VALID[key] then
      fail(label, 'contains unknown direction ' .. tostring(key), (level or 1) + 1)
    end
    if present ~= true and present ~= false and present ~= nil then
      fail(label, 'direction ' .. tostring(key) .. ' must be boolean', (level or 1) + 1)
    end
    if present then
      out[key] = true
    end
  end
  if out.any and (out.up or out.down) then
    fail(label, 'cannot combine any with directional entries', (level or 1) + 1)
  end
  return out
end

function M.merge_supply(dst, src)
  dst = dst or {}
  for key in pairs(src or {}) do
    if VALID[key] then
      dst[key] = true
    end
  end
  return dst
end

local function supply_empty(value)
  return not (value and (value.up or value.down or value.any))
end

function M.may_supply(value, demand)
  if supply_empty(value) then
    return false
  end
  if value.any or demand == nil then
    return true
  end
  return value[demand] == true
end



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

local function stage_log(summary, patch, trail)
  if not summary then
    return clone_log(patch)
  end
  for i = 1, #(patch.ops or {}) do
    push(trail, summary.ops, copy_operation(patch.ops[i]))
  end
  return summary
end

local function constrain_log(_, patch, orientation)
  if not orientation then
    return clone_log(patch)
  end
  return filter_operations(patch, orientation == 'up' and 'down' or 'up')
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
function Machine.serialise(patch, relation, out)
  for i = 1, #(patch.steps or {}) do
    local step = patch.steps[i]
    out[#out + 1] = { serial = step.serial, value = step.value, relation = relation }
  end
end
function Machine.change(serial, value)
  return { kind = Machine.name, steps = { { serial = serial, value = value } } }
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
Presence.stage = stage_log
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
Presence.constraint = constrain_log
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
FiniteMap.stage = stage_log
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
FiniteMap.constraint = constrain_log
FiniteMap.supplies = log_supplies

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

local function clone_patch(patch)
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
    return clone_patch(right)
  end
  if not right then
    return clone_patch(left)
  end
  return M.get(location).join(location, left, right, composition)
end

function M.constraint(location, patch, orientation)
  return M.get(location).constraint(location, patch, orientation)
end

function M.supplies(location, patch)
  return M.get(location).supplies(patch)
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
