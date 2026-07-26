-- Private post-commit hold for irreversible host acquisitions.
--
-- A HostHold is an ordinary child Lifetime used only between an irreversible
-- host return and conversion of that value into a normal child Lifetime.
-- Closing the hold resolves every value not released into the Lifetime tree.

local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local HostError = require('fibers.host.error')
local IOAudit = require('fibers.diagnostics.io')

local HostHold = {}
HostHold.__index = HostHold
local next_id = 0

local function close_value(value, close, reason)
  if value == nil then
    return true
  end
  if close then
    return close(value, reason)
  end
  if type(value.close) == 'function' then
    return value:close(reason)
  end
  return true
end

function HostHold.new(name)
  next_id = next_id + 1
  local id = 'host-hold-' .. tostring(next_id)
  local self = setmetatable({
    name = name or id,
    values = {},
    order = {},
    taken = {},
    closed = false,
  }, HostHold)
  Lifetime.define(self, {
    name = self.name,
    role = 'host_hold',
    closure = Closure.protocol({
      name = 'host_hold',
      finish_op = function(_ctx, record, close)
        return Op.always(true):wrap(function()
          local ok, err = record.item:close(close.reason or 'lifetime closure')
          if not ok then
            error(err, 0)
          end
          return true
        end)
      end,
    }),
  })
  return self
end

function HostHold:is_empty()
  return next(self.values) == nil
end

function HostHold:hold(key, value, close)
  if type(key) ~= 'string' or key == '' then
    close_value(value, close, 'host hold refused')
    return nil, HostError.protocol('host_hold', 'hold', 'host-hold key must be a non-empty string')
  end
  if value == nil then
    return nil, HostError.protocol('host_hold', 'hold', 'cannot hold nil')
  end
  if self.closed or self.values[key] ~= nil or self.taken[key] then
    close_value(value, close, 'host hold refused')
    return nil, HostError.protocol('host_hold', 'hold', 'host-hold key is unavailable', { key = key })
  end
  self.values[key] = { value = value, close = close }
  self.order[#self.order + 1] = key
  IOAudit.hold(value, self, { kind = 'host_handle', entry = key })
  return value
end

function HostHold:hold_many(entries)
  if type(entries) ~= 'table' then
    return nil, HostError.protocol('host_hold', 'hold_many', 'entries must be an ordered array')
  end
  local inserted = {}
  for i = 1, #entries do
    local entry = entries[i]
    if type(entry) ~= 'table' then
      return nil, HostError.protocol('host_hold', 'hold_many', 'entry must be a table', { index = i })
    end
    local key = entry.key or entry.name or entry[1]
    local value = entry.value
    if value == nil then
      value = entry[2]
    end
    local close = entry.close or entry[3]
    local got, err = self:hold(key, value, close)
    if not got then
      for j = #inserted, 1, -1 do
        local inserted_key = inserted[j]
        local rec = self.values[inserted_key]
        self.values[inserted_key] = nil
        if rec then
          IOAudit.release(rec.value, self)
          close_value(rec.value, rec.close, 'host hold batch rolled back')
        end
      end
      return nil, err
    end
    inserted[#inserted + 1] = key
  end
  return true
end

function HostHold:release(key, expected)
  local rec = self.values[key]
  if not rec then
    return nil, HostError.protocol('host_hold', 'release', 'host-hold key is empty', { key = key })
  end
  if expected ~= nil and rec.value ~= expected then
    return nil, HostError.protocol('host_hold', 'release', 'host-hold value mismatch', { key = key })
  end
  self.values[key] = nil
  self.taken[key] = true
  IOAudit.release(rec.value, self)
  return rec.value
end

function HostHold:release_all()
  local out = {}
  for i = 1, #self.order do
    local key = self.order[i]
    local rec = self.values[key]
    if rec then
      out[key] = rec.value
      self.values[key] = nil
      self.taken[key] = true
      IOAudit.release(rec.value, self)
    end
  end
  return out
end

function HostHold:close(reason)
  if self.closed then
    return true
  end
  self.closed = true
  local errors = {}
  for i = #self.order, 1, -1 do
    local key = self.order[i]
    local rec = self.values[key]
    self.values[key] = nil
    if rec then
      IOAudit.release(rec.value, self)
      local ok, err = close_value(rec.value, rec.close, reason)
      if not ok then
        errors[#errors + 1] = { key = key, error = err }
      end
    end
  end
  if #errors > 0 then
    return nil,
      HostError.protocol('host_hold', 'close', 'one or more held values failed to close', {
        errors = errors,
      })
  end
  return true
end

return HostHold
