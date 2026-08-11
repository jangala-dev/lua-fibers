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
    if type(present) ~= 'boolean' then
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
  for key in pairs(src) do
    dst[key] = true
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

local function copy_array(values)
  local out = {}
  for i = 1, #values do out[i] = values[i] end
  return out
end

local function clone_machine(patch)
  return { kind = 'machine', steps = copy_array(patch.steps) }
end

local function clone_log(patch)
  return { kind = patch.kind, ops = copy_array(patch.ops) }
end

local function clone_map_value(location, value)
  local out = {}
  local clone = location.clone_value
  for key, item in pairs(value) do
    if clone then item = clone(item) end
    out[key] = item
  end
  return out
end

local function merge_steps(left, right)
  local out, i, j = {}, 1, 1
  while i <= #left and j <= #right do
    local take_left = left[i].serial <= right[j].serial
    local step = take_left and left[i] or right[j]
    out[#out + 1] = step
    if take_left then
      i = i + 1
    else
      j = j + 1
    end
  end
  while i <= #left do
    out[#out + 1] = left[i]
    i = i + 1
  end
  while j <= #right do
    out[#out + 1] = right[j]
    j = j + 1
  end
  return out
end

local function filter_operations(patch, direction)
  local ops = {}
  for i = 1, #patch.ops do
    local op = patch.ops[i]
    local up = op.op == 'put'
    local down = op.op == 'remove' or op.op == 'take'
    if (direction == 'up' and up) or (direction == 'down' and down) then
      ops[#ops + 1] = op
    end
  end
  return #ops > 0 and { kind = patch.kind, ops = ops } or nil
end

local function log_supplies(patch)
  local out = {}
  for i = 1, #patch.ops do
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
  for i = 1, #patch.ops do
    push(trail, summary.ops, patch.ops[i])
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
function Replace.join(location, left, right)
  local equal = location.value_equal
  if not (equal and equal(left.value, right.value)) and left.value ~= right.value then
    return nil
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
function Add.valid(location, patch)
  local final, owner = location.value + patch.delta, location.owner
  return (owner._min == nil or final >= owner._min) and (owner._max == nil or final <= owner._max)
end

local Machine = { name = 'machine' }
Machine.clone = clone_machine
function Machine.apply(_, value, patch)
  local steps = patch.steps
  if #steps == 0 then
    return value
  end
  return steps[#steps].value
end
function Machine.stage(summary, patch, trail)
  if not summary then
    return Machine.clone(patch)
  end
  local last, first = summary.steps[#summary.steps], patch.steps[1]
  if last and first and last.serial >= first.serial then
    error('machine steps must be staged in increasing serial order', 3)
  end
  for i = 1, #patch.steps do
    local step = patch.steps[i]
    push(trail, summary.steps, step)
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
  for i = 1, #patch.steps do
    local step = patch.steps[i]
    out[#out + 1] = { serial = step.serial, value = step.value, relation = relation }
  end
end
function Machine.change(serial, value)
  return { kind = Machine.name, steps = { { serial = serial, value = value } } }
end

local function merge_map_operation(location, left, right, composition)
  if left.op == 'put' and right.op == 'put' then
    if location.put_equal and left.value == right.value then
      return { left }
    end
    if
      (composition == 'interacting' or composition == 'external')
      and left.policy == 'overwrite'
      and right.policy == 'overwrite'
    then
      return { right }
    end
    return nil
  end
  if (left.op == 'put' and right.op == 'take') or (left.op == 'take' and right.op == 'put') then
    local put = left.op == 'put' and left or right
    return { put, left.op == 'take' and left or right }
  end
  if left.op == 'remove' and right.op == 'remove' and location.remove_idempotent then
    return { left }
  end
  return nil
end

local PRESENCE_MERGE = { put_equal = true, remove_idempotent = true }
local Presence = { name = 'presence' }
Presence.clone = clone_log
function Presence.apply(_, value, patch)
  for i = 1, #patch.ops do
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
  if #left.ops ~= 1 or #right.ops ~= 1 then return nil end
  local ops = merge_map_operation(PRESENCE_MERGE, left.ops[1], right.ops[1])
  return ops and { kind = 'presence', ops = ops } or nil
end
Presence.constraint = constrain_log
Presence.supplies = log_supplies

local FiniteMap = { name = 'finite_map' }
FiniteMap.clone = clone_log
function FiniteMap.apply(location, value, patch)
  local out = clone_map_value(location, value)
  for i = 1, #patch.ops do
    local op = patch.ops[i]
    if op.op == 'put' then
      local item = op.value
      if location.clone_value then item = location.clone_value(item) end
      out[op.key] = item
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
  local a, b = left.ops, right.ops
  if #a == 1 and #b == 1 then
    if a[1].key ~= b[1].key then
      return { kind = 'finite_map', ops = { a[1], b[1] } }
    end
    local ops = merge_map_operation(location, a[1], b[1], composition)
    return ops and { kind = 'finite_map', ops = ops } or nil
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
    for i = 1, #values do
      out[#out + 1] = values[i]
    end
  end
  for key in pairs(keys) do
    local x, y = by_left[key], by_right[key]
    if not x then
      append(y)
    elseif not y then
      append(x)
    elseif #x == 1 and #y == 1 then
      local merged = merge_map_operation(location, x[1], y[1], composition)
      if not merged then return nil end
      append(merged)
    else
      return nil
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

local REQUIRED_ALGEBRA_METHODS = { 'clone', 'apply', 'stage', 'join', 'constraint', 'supplies' }

function M.get(value)
  if type(value) == 'table' then
    for i = 1, #REQUIRED_ALGEBRA_METHODS do
      local method = REQUIRED_ALGEBRA_METHODS[i]
      if type(value[method]) ~= 'function' then
        error('custom location algebra requires ' .. method, 3)
      end
    end
    return value
  end
  local algebra = BY_NAME[value]
  if not algebra then
    error('unknown location algebra: ' .. tostring(value), 3)
  end
  return algebra
end

function M.apply(location, value, patch)
  return location.algebra.apply(location, value, patch)
end

function M.stage(location, summary, patch, trail)
  local algebra = location.algebra
  if patch.kind ~= algebra.name then
    error(algebra.name .. ' location requires ' .. algebra.name .. ' patch', 3)
  end
  return algebra.stage(summary, patch, trail)
end

function M.join(location, left, right, composition)
  local algebra = location.algebra
  if not left then
    return right and algebra.clone(right) or nil
  end
  if not right then
    return algebra.clone(left)
  end
  return algebra.join(location, left, right, composition)
end

function M.constraint(location, patch, orientation)
  return location.algebra.constraint(location, patch, orientation)
end

function M.supplies(location, patch)
  return location.algebra.supplies(patch)
end

function M.serialise(location, summary, relation, out)
  local serialise = location.algebra.serialise
  if serialise then
    serialise(summary, relation, out)
  end
  return out
end

function M.machine_change(location, serial, value)
  local change = location.algebra.change
  if not change then
    error('location algebra does not accept machine changes', 3)
  end
  return change(serial, value)
end

return M
