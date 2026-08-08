-- Debugging and qualification records for external-resource lifecycles.
--
-- The audit is deliberately observational: production semantics do not depend
-- on it.  Records use weak keys so inspection cannot keep host handles or
-- reactor entries alive.  Facilities report custody and registration changes
-- here, allowing contract tests and embedders to detect leaked handles, stale
-- registrations, duplicate transfers, and failed closure.

local Audit = {}
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local records = setmetatable({}, { __mode = 'k' })
local runtime_values = setmetatable({}, { __mode = 'k' })
local runtime_stats = setmetatable({}, { __mode = 'k' })
local next_id = 0

local function runtime_bucket(rt)
  if not rt then
    return nil
  end
  local bucket = runtime_values[rt]
  if not bucket then
    bucket = setmetatable({}, { __mode = 'k' })
    runtime_values[rt] = bucket
  end
  return bucket
end

local function stats(rt)
  if not rt then
    return nil
  end
  local out = runtime_stats[rt]
  if not out then
    out = {
      stale_ready = 0,
      services = 0,
      controls = 0,
      violations = 0,
    }
    runtime_stats[rt] = out
  end
  return out
end

local function label(value)
  if type(value) == 'table' then
    return Label.describe(value, value.kind or tostring(value))
  end
  return tostring(value)
end

local function append(rec, event, fields)
  local row = { event = event }
  for key, value in pairs(fields or {}) do
    row[key] = value
  end
  rec.history[#rec.history + 1] = row
  if #rec.history > 32 then
    table.remove(rec.history, 1)
  end
end

local function ensure(value, fields)
  if value == nil then
    return nil
  end
  local rec = records[value]
  if not rec then
    next_id = next_id + 1
    rec = {
      id = next_id,
      value_label = label(value),
      kind = fields and fields.kind or 'external',
      state = 'created',
      custodian = nil,
      hold_holder = nil,
      runtime = nil,
      close_attempts = 0,
      registration_count = 0,
      service_count = 0,
      violations = {},
      history = {},
    }
    records[value] = rec
    append(rec, 'created', fields)
  elseif fields then
    rec.kind = fields.kind or rec.kind
  end
  return rec
end

local function violation(rec, code, fields)
  if not rec then
    return
  end
  local item = { code = code }
  for key, value in pairs(fields or {}) do
    item[key] = value
  end
  rec.violations[#rec.violations + 1] = item
  append(rec, 'violation', item)
  local s = stats(rec.runtime)
  if s then
    s.violations = s.violations + 1
  end
end

function Audit.created(value, fields)
  return ensure(value, fields)
end

function Audit.bind(value, rt)
  local rec = ensure(value)
  if not rec then
    return
  end
  if rec.runtime and rec.runtime ~= rt then
    violation(rec, 'runtime_rebind', { previous = rec.runtime, current = rt })
  end
  rec.runtime = rt
  local bucket = runtime_bucket(rt)
  if bucket then
    bucket[value] = true
  end
  append(rec, 'bound', { runtime = rt })
end

function Audit.hold(value, holder, fields)
  local rec = ensure(value, { kind = fields and fields.kind or 'host_handle' })
  if not rec then
    return
  end
  if rec.state == 'closed' then
    violation(rec, 'hold_closed', { holder = holder })
  elseif rec.custodian and rec.custodian ~= holder and rec.state ~= 'released' then
    violation(rec, 'conflicting_hold', { previous = rec.custodian, current = holder })
  end
  rec.custodian = holder
  rec.hold_holder = holder
  rec.state = 'held'
  append(rec, 'held', {
    holder = holder,
    entry = fields and fields.entry,
  })
end

function Audit.transfer(value, custodian, fields)
  local rec = ensure(value, { kind = fields and fields.kind or 'host_handle' })
  if not rec then
    return
  end
  if rec.state == 'closed' then
    violation(rec, 'transfer_closed', { custodian = custodian })
  end
  rec.custodian = custodian
  rec.state = 'in_custody'
  append(rec, 'transferred', {
    custodian = custodian,
    role = fields and fields.role,
  })
end

function Audit.release(value, actor)
  local rec = ensure(value)
  if not rec then
    return
  end
  if rec.hold_holder == actor then
    rec.hold_holder = nil
    if rec.custodian == actor then
      rec.custodian = nil
      rec.state = 'released'
    end
    append(rec, 'released', { actor = actor })
    return
  end
  if actor ~= nil and rec.custodian ~= nil and rec.custodian ~= actor then
    violation(rec, 'release_wrong_custodian', { expected = rec.custodian, got = actor })
    return
  end
  if rec.custodian == actor then
    rec.custodian = nil
    rec.state = 'released'
  end
  append(rec, 'released', { actor = actor })
end

function Audit.closing(value, reason)
  local rec = ensure(value)
  if not rec then
    return
  end
  rec.close_attempts = rec.close_attempts + 1
  if rec.state == 'closed' then
    append(rec, 'close_repeated', { reason = reason })
    return
  end
  rec.state = 'closing'
  append(rec, 'closing', { reason = reason })
end

function Audit.closed(value, ok, err, reason)
  local rec = ensure(value)
  if not rec then
    return
  end
  if ok then
    rec.state = 'closed'
    rec.custodian = nil
    rec.close_error = nil
    append(rec, 'closed', { reason = reason })
  else
    rec.state = 'close_failed'
    rec.close_error = err
    append(rec, 'close_failed', { reason = reason, error = err })
  end
end

function Audit.register(entry, rt, fields)
  local rec = ensure(entry, { kind = 'reactor_registration' })
  if not rec then
    return
  end
  Audit.bind(entry, rt)
  rec.state = 'registered'
  rec.registration_count = rec.registration_count + 1
  rec.mode = fields and fields.mode or rec.mode
  rec.key = fields and fields.key or rec.key
  append(rec, 'registered', { mode = rec.mode, key = rec.key })
end

function Audit.retire(entry, err, reason)
  local rec = ensure(entry, { kind = 'reactor_registration' })
  if not rec then
    return
  end
  rec.state = err and 'retire_failed' or 'retired'
  rec.retire_error = err
  rec.custodian = nil
  append(rec, err and 'retire_failed' or 'retired', { reason = reason, error = err })
end

function Audit.service(entry)
  local rec = ensure(entry, { kind = 'reactor_registration' })
  if not rec then
    return
  end
  rec.service_count = rec.service_count + 1
  local s = stats(rec.runtime)
  if s then
    s.services = s.services + 1
  end
end

function Audit.control(rt)
  local s = stats(rt)
  if s then
    s.controls = s.controls + 1
  end
end

function Audit.stale_ready(rt)
  local s = stats(rt)
  if s then
    s.stale_ready = s.stale_ready + 1
  end
end

function Audit.record(value)
  return records[value]
end

local REPORT_OPTIONS = { include_closed = true, include_history = true }
local ASSERT_OPTIONS = { label = true, allow_violations = true }

local function report_options(opts, level)
  opts = Contract.options(opts, REPORT_OPTIONS, 'I/O audit report options', level or 3)
  Contract.optional_boolean(opts.include_closed, 'I/O audit include_closed', level or 3)
  Contract.optional_boolean(opts.include_history, 'I/O audit include_history', level or 3)
  return opts
end

local function include_record(rec, opts)
  if opts.include_closed then
    return true
  end
  return rec.state ~= 'closed' and rec.state ~= 'retired'
end

function Audit.report(rt, opts)
  opts = report_options(opts, 3)
  local items = {}
  local counts = {}
  local bucket = rt and runtime_values[rt] or nil
  local function add(value)
    local rec = records[value]
    if not rec or not include_record(rec, opts) then
      return
    end
    counts[rec.state] = (counts[rec.state] or 0) + 1
    items[#items + 1] = {
      id = rec.id,
      label = rec.value_label,
      kind = rec.kind,
      state = rec.state,
      custodian = rec.custodian,
      hold_holder = rec.hold_holder,
      close_attempts = rec.close_attempts,
      registration_count = rec.registration_count,
      service_count = rec.service_count,
      close_error = rec.close_error,
      retire_error = rec.retire_error,
      violations = rec.violations,
      history = opts.include_history and rec.history or nil,
    }
  end
  if bucket then
    for value in pairs(bucket) do
      add(value)
    end
  elseif rt == nil then
    for value in pairs(records) do
      add(value)
    end
  end
  table.sort(items, function(a, b)
    return a.id < b.id
  end)
  local s = rt and stats(rt) or nil
  return {
    counts = counts,
    items = items,
    stats = s and {
      stale_ready = s.stale_ready,
      services = s.services,
      controls = s.controls,
      violations = s.violations,
    } or nil,
  }
end

function Audit.active(rt)
  return Audit.report(rt).items
end

function Audit.assert_clean(rt, opts)
  opts = Contract.options(opts, ASSERT_OPTIONS, 'I/O audit assert_clean options', 3)
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'I/O audit label', 3) end
  Contract.optional_boolean(opts.allow_violations, 'I/O audit allow_violations', 3)
  local snapshot = Audit.report(rt)
  local bad = {}
  for _, item in ipairs(snapshot.items) do
    if item.kind == 'reactor_registration' then
      if item.state ~= 'retired' then
        bad[#bad + 1] = item
      end
    elseif item.state ~= 'closed' then
      bad[#bad + 1] = item
    end
  end
  if #bad > 0 then
    local labels = {}
    for _, item in ipairs(bad) do
      labels[#labels + 1] = item.label .. '(' .. item.kind .. ':' .. item.state .. ')'
    end
    error((opts.label or 'I/O audit') .. ' found live resources: ' .. table.concat(labels, ', '), 2)
  end
  if snapshot.stats and snapshot.stats.violations > 0 and opts.allow_violations ~= true then
    error((opts.label or 'I/O audit') .. ' recorded lifecycle violations', 2)
  end
  return true
end

function Audit.reset_for_test()
  records = setmetatable({}, { __mode = 'k' })
  runtime_values = setmetatable({}, { __mode = 'k' })
  runtime_stats = setmetatable({}, { __mode = 'k' })
  next_id = 0
end

return Audit
