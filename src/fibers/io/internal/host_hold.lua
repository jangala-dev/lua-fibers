-- Private post-commit hold for irreversible host acquisitions.
--
-- A HostHold is an ordinary child Lifetime used only between an irreversible
-- host return and conversion of that value into a normal child Lifetime.
-- Closing the hold resolves every value not released into the Lifetime tree.

local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')
local Protected = require('fibers.protected')
local Contract = require('fibers.internal.contract')

local HostHold = {}
HostHold.__index = HostHold
local next_id = 0

local function close_value(value, close, reason)
  if value == nil then return true end
  return close(value, reason)
end

local function safe_close(value, close, reason)
  local called, ok, err = Protected.pcall(close_value, value, close, reason)
  if not called then
    return nil, IOError.protocol('host_hold', 'close', 'held value close raised', { cause = ok })
  end
  return ok, err
end

function HostHold.new()
  next_id = next_id + 1
  local id = 'host-hold-' .. tostring(next_id)
  local self = setmetatable({
    _fibers_id = id,
    values = {},
    order = {},
    taken = {},
    closed = false,
  }, HostHold)
  Lifetime.define(self, {
    label = nil,
    role = 'host_hold',
    closure = Closure.protocol({
      name = 'host_hold',
      finish_op = function(_ctx, record, close)
        return Op.always(true):wrap(function()
          local ok, err = record.item:close(close.reason or 'lifetime closure')
          if not ok then error(err, 0) end
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
  Contract.non_empty_string(key, 'host-hold key', 2)
  if value == nil then error('host-hold value must not be nil', 2) end
  Contract.func(close, 'host-hold closer', 2)

  if self.closed or self.values[key] ~= nil or self.taken[key] then
    local closed, close_err = safe_close(value, close, 'host hold refused')
    if not closed then
      return nil, IOError.protocol('host_hold', 'hold', 'host-hold key is unavailable and refused value failed to close', {
        key = key,
        close_error = close_err,
      })
    end
    return nil, IOError.protocol('host_hold', 'hold', 'host-hold key is unavailable', { key = key })
  end
  self.values[key] = { value = value, close = close }
  self.order[#self.order + 1] = key
  IOAudit.hold(value, self, { kind = 'host_handle', entry = key })
  return value
end

local HOLD_ENTRY_OPTIONS = { key = true, value = true, close = true }

local function validate_entries(entries)
  Contract.table(entries, 'host-hold entries', 3)
  local count = #entries
  for key in pairs(entries) do
    if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) or key > count then
      error('host-hold entries must be a dense ordered array', 3)
    end
  end
  for i = 1, count do
    local entry = Contract.options(entries[i], HOLD_ENTRY_OPTIONS, 'host-hold entry', 3)
    Contract.non_empty_string(entry.key, 'host-hold entry key', 3)
    if entry.value == nil then error('host-hold entry value must not be nil', 3) end
    Contract.func(entry.close, 'host-hold entry closer', 3)
  end
  return count
end

function HostHold:hold_many(entries)
  local count = validate_entries(entries)
  local inserted = {}
  for i = 1, count do
    local entry = entries[i]
    local got, err = self:hold(entry.key, entry.value, entry.close)
    if not got then
      local rollback_errors = {}
      for j = #inserted, 1, -1 do
        local inserted_key = inserted[j]
        local rec = self.values[inserted_key]
        self.values[inserted_key] = nil
        if rec then
          IOAudit.release(rec.value, self)
          local closed, close_err = safe_close(rec.value, rec.close, 'host hold batch rolled back')
          if not closed then
            rollback_errors[#rollback_errors + 1] = { key = inserted_key, error = close_err }
          end
        end
      end
      if #rollback_errors > 0 then
        return nil, IOError.protocol('host_hold', 'hold_many', 'host-hold batch failed and rollback was incomplete', {
          cause = err,
          rollback_errors = rollback_errors,
        })
      end
      return nil, err
    end
    inserted[#inserted + 1] = entry.key
  end
  return true
end

function HostHold:release(key, expected)
  local rec = self.values[key]
  if not rec then
    return nil, IOError.protocol('host_hold', 'release', 'host-hold key is empty', { key = key })
  end
  if expected ~= nil and rec.value ~= expected then
    return nil, IOError.protocol('host_hold', 'release', 'host-hold value mismatch', { key = key })
  end
  self.values[key] = nil
  self.taken[key] = true
  IOAudit.release(rec.value, self)
  return rec.value
end

-- Remove and close one held value without disturbing sibling entries.  This is
-- used when conversion of one host-owned offer into its public Lifetime fails:
-- the failed value must be resolved, but the source hold must remain live for
-- other queued offers.
function HostHold:discard(key, expected, reason)
  local rec = self.values[key]
  if not rec then
    return nil, IOError.protocol('host_hold', 'discard', 'host-hold key is empty', { key = key })
  end
  if expected ~= nil and rec.value ~= expected then
    return nil, IOError.protocol('host_hold', 'discard', 'host-hold value mismatch', { key = key })
  end

  self.values[key] = nil
  self.taken[key] = true
  IOAudit.release(rec.value, self)

  local ok, err = safe_close(rec.value, rec.close, reason or 'host value discarded')
  if not ok then
    return nil, IOError.protocol('host_hold', 'discard', 'held value failed to close', {
      key = key,
      cause = err,
    })
  end
  return true
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
  if self.closed then return true end
  self.closed = true
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
    return nil, IOError.protocol('host_hold', 'close', 'one or more held values failed to close', {
      errors = errors,
    })
  end
  return true
end

return HostHold
