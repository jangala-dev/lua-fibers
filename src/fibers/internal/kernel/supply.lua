-- Canonical directional supply relation used by trusted resource programmes.
--
-- A supply set states which demand directions a transition or patch may make
-- ready in the same candidate world.  Omission means no supply; `any` is an
-- explicit conservative declaration, never a compatibility fallback.

local M = {}

local VALID = { up = true, down = true, any = true }

local function fail(label, message, level)
  error((label or 'supply declaration') .. ' ' .. message, (level or 1) + 1)
end

function M.normalise(value, label, level)
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

function M.merge_into(dst, src)
  dst = dst or {}
  for key in pairs(src or {}) do
    if VALID[key] then
      dst[key] = true
    end
  end
  return dst
end

function M.is_empty(value)
  return not (value and (value.up or value.down or value.any))
end

function M.may_supply(value, demand)
  if M.is_empty(value) then
    return false
  end
  if value.any or demand == nil then
    return true
  end
  return value[demand] == true
end

function M.describe(value)
  local parts = {}
  if value and value.any then parts[#parts + 1] = 'any' end
  if value and value.up then parts[#parts + 1] = 'up' end
  if value and value.down then parts[#parts + 1] = 'down' end
  if #parts == 0 then
    return 'none'
  end
  table.sort(parts)
  return table.concat(parts, '+')
end

return M
