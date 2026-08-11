-- Lexical ownership for irreversible host acquisitions.
--
-- Values live here only until a normal Fibers facility adopts them. The guard
-- is deliberately not a Lifetime: its protected extent is the host setup call
-- itself, and every unreleased value is closed on return or unwind.

local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')
local Protected = require('fibers.protected')
local Contract = require('fibers.internal.contract')

local Acquired = {}
Acquired.__index = Acquired
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function safe_close(value, close, reason)
  local called, ok, err = Protected.pcall(close, value, reason)
  if not called then
    return nil, IOError.protocol('host', 'acquire_cleanup', 'acquired value close raised', { cause = ok })
  end
  return ok, err
end

function Acquired.new()
  return setmetatable({ values = {}, order = {} }, Acquired)
end

function Acquired:hold(key, value, close)
  Contract.non_empty_string(key, 'acquired value key', 2)
  if value == nil then error('acquired value must not be nil', 2) end
  Contract.func(close, 'acquired value closer', 2)
  if self.values[key] ~= nil then error('duplicate acquired value key: ' .. key, 2) end
  self.values[key] = { value = value, close = close }
  self.order[#self.order + 1] = key
  IOAudit.hold(value, self, { kind = 'host_handle', entry = key })
  return value
end

function Acquired:release(key, expected)
  local rec = self.values[key]
  if rec == nil then return nil end
  if expected ~= nil and rec.value ~= expected then
    error('acquired value mismatch for ' .. tostring(key), 2)
  end
  self.values[key] = nil
  IOAudit.release(rec.value, self)
  return rec.value
end

function Acquired:close(reason)
  local errors = {}
  for i = #self.order, 1, -1 do
    local key = self.order[i]
    local rec = self.values[key]
    self.values[key] = nil
    if rec then
      IOAudit.release(rec.value, self)
      local ok, err = safe_close(rec.value, rec.close, reason)
      if not ok then errors[#errors + 1] = { key = key, error = err } end
    end
  end
  if #errors > 0 then
    return nil, IOError.protocol('host', 'acquire_cleanup', 'one or more acquired values failed to close', {
      errors = errors,
    })
  end
  return true
end

-- Run a yieldable setup region and close every value not explicitly released.
-- Cleanup failure is returned only on an otherwise successful return; an
-- already-thrown failure remains authoritative and cleanup is best-effort.
function Acquired.run(fn, ...)
  Contract.func(fn, 'acquisition function', 2)
  local guard = Acquired.new()
  local result = pack(Protected.pcall(fn, guard, ...))
  local closed, close_err = guard:close(result[1] and 'host acquisition completed' or result[2])
  if not result[1] then error(result[2], 0) end
  if not closed then return nil, close_err end
  return unpack_(result, 2, result.n)
end

return Acquired
