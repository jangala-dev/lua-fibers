---A bounded, non-blocking Fibers application embedded in an external host.
---
---`Application:advance` is the canonical boundary. An embedding host loop
---supplies an absolute time horizon and a deterministic step allowance. The
---application advances until it settles, reaches a host-actionable wait, or
---exhausts the current turn. Host horizon exhaustion retains exact proof and
---fiber progress; it is not semantic Retry and cannot enable `or_else`.

local WaitSet = require('fibers.embed.wait_set')
local Closure = require('fibers.closure')
local Protected = require('fibers.protected')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local ScopeOutcome = require('fibers.scope.outcome')
local ScopeResult = ScopeOutcome.Result
local Contract = require('fibers.internal.contract')

local Application = {}
Application.__index = Application

local APPLICATION_OPTIONS = {
  host = true, closure = true,
  label = Contract.non_empty_string, runtime_options = Contract.table,
  status_marker = Contract.non_empty_string, application_marker = Contract.non_empty_string,
  owns_host = Contract.boolean, on_status = Contract.func,
  max_steps_per_turn = Contract.positive_integer,
  max_work_per_step = Contract.positive_integer,
  max_external_per_turn = Contract.positive_integer,
  max_seconds_per_turn = Contract.non_negative_number,
}

local ADVANCE_OPTIONS = {
  max_steps = Contract.positive_integer, max_work = Contract.positive_integer,
  max_external = Contract.positive_integer, horizon = Contract.finite_number,
  max_seconds = Contract.non_negative_number,
}

local function copy(value, label)
  value = Contract.table(value, label or 'table', 3)
  local out = {}
  for key, item in pairs(value) do
    out[key] = item
  end
  return out
end


local function default(value, fallback)
  return value == nil and fallback or value
end

local function runtime_options(opts, host)
  local out = opts.runtime_options == nil and {} or copy(opts.runtime_options, 'Application runtime_options')
  out.host = host
  return out
end

local function public_status(self, fields)
  fields = fields or {}
  fields._fibers_embed_status = true
  if self._status_marker then fields[self._status_marker] = true end
  fields.application = self
  fields.runtime = self.runtime
  fields.scope = self.scope
  fields.result = self._result
  self._status = fields
  if self.on_status then
    self.on_status(fields)
  end
  return fields
end

local function earliest_deadline(status)
  local interests = status and status.interests or {}
  return WaitSet.build(interests).deadline, interests
end

local function unsupported_interest(self, interests)
  local supports = self.supports_interest or self.host.supports_interest
  if type(supports) ~= 'function' then return nil end
  for i = 1, #(interests or {}) do
    local interest = interests[i]
    local ok, reason = supports(self.host, interest, self)
    if ok == false then
      return interest, reason
    end
  end
  return nil
end

local function runtime_has_ready(runtime)
  return (runtime._ready_head or 1) <= (runtime._ready_tail or 0)
end

function Application.new(fn, opts)
  opts = Contract.record(opts, APPLICATION_OPTIONS, 'Application.new options', 2)
  if type(fn) ~= 'function' then
    error((opts.label or 'Embed.prepare') .. ' expects a root function', 2)
  end
  local host = opts.host
  if type(host) ~= 'table' then
    error((opts.label or 'Embed.prepare') .. ' requires an embedding host', 2)
  end

  local label = opts.label or 'root'
  local runtime = Runtime.new(runtime_options(opts, host))
  local scope = Scope.new( {
    runtime = runtime,
    closure = opts.closure or Closure.nursery({ name = label }),
  }):label(label)

  local self = setmetatable({
    _fibers_embed_application = true,
    _status_marker = opts.status_marker,
    _application_marker = opts.application_marker,
    host = host,
    runtime = runtime,
    scope = scope,
    _root_result = nil,
    _result = nil,
    _status = nil,
    _settled = false,
    _finalised = false,
    _advancing = false,
    _closed = false,
    _owns_host = opts.owns_host ~= false,
    _next_deadline = nil,
    max_steps_per_turn = default(opts.max_steps_per_turn, 128),
    max_work_per_step = default(opts.max_work_per_step, 512),
    max_external_per_turn = default(opts.max_external_per_turn, 4096),
    max_seconds_per_turn = default(opts.max_seconds_per_turn, 0.002),
    on_status = opts.on_status,
  }, Application)

  if self._application_marker then self[self._application_marker] = true end
  host.application = self
  runtime:_spawn_raw(function()
    self._root_result = scope:try_run(fn)
    return self._root_result
  end,  scope):label(label)

  return self
end

function Application.is(value)
  return type(value) == 'table' and value._fibers_embed_application == true
end

function Application:is_settled()
  return self._settled == true
end

function Application:result()
  return self._result
end

function Application:status()
  return self._status
end

function Application:now()
  return self.runtime:now()
end

function Application:_complete(runtime_status, runtime_error)
  if self._settled then
    return public_status(self, {
      state = 'settled',
      reason = 'complete',
      runtime_status = runtime_status or (self._status and self._status.runtime_status),
      needs_immediate_resume = false,
    })
  end

  local finalise_error
  if not self._finalised then
    self._finalised = true
    local ok, err = Protected.pcall(function()
      return self.runtime:_finalize()
    end)
    if not ok then
      finalise_error = err
    end
  end
  runtime_error = runtime_error or finalise_error

  local result = self._root_result
  if runtime_error ~= nil then
    local closure_failures = ScopeOutcome.closure_failures(runtime_error)
    result = ScopeResult.fail({
      reason = 'runtime_error',
      primary = runtime_error,
      report = self.scope:_make_report(runtime_error, {}, {
        reason = 'runtime_error',
        closure_failures = closure_failures,
      }),
      closure_failures = closure_failures,
      runtime_status = runtime_status,
    })
  elseif result == nil then
    result = ScopeResult.fail({
      reason = 'runtime_pending',
      primary = runtime_status,
      report = self.scope:_make_report(runtime_status, {}, { reason = 'runtime_pending' }),
      runtime_status = runtime_status,
    })
  end

  result.runtime_status = runtime_status
  result.runtime = self.runtime
  result.scope = self.scope
  self._result = result
  self._settled = true
  if type(self._detach_scheduler) == 'function' then self:_detach_scheduler() end
  if type(self.host.mark_done) == 'function' then self.host:mark_done(result) end
  if self._owns_host then
    if type(self.host.close) == 'function' then self.host:close() end
  end

  return public_status(self, {
    state = 'settled',
    reason = result.ok and 'complete' or result.reason or 'failed',
    runtime_status = runtime_status,
    needs_immediate_resume = false,
  })
end

local function advance_limits(self, opts)
  opts = Contract.record(opts, ADVANCE_OPTIONS, 'Application:advance options', 3)
  local max_steps =
    default(opts.max_steps, self.max_steps_per_turn)
  local max_work =
    default(opts.max_work, self.max_work_per_step)
  local max_external = default(opts.max_external, self.max_external_per_turn)

  local horizon = opts.horizon
  if horizon == nil then horizon = self:now() + default(opts.max_seconds, self.max_seconds_per_turn) end
  return max_steps, max_work, max_external, horizon
end

local function pending_turn(self, reason, runtime_status, fields)
  fields = fields or {}
  local deadline, interests = earliest_deadline(runtime_status)
  fields.state = 'pending'
  fields.reason = reason
  fields.runtime_status = runtime_status
  fields.interests = interests
  fields.next_deadline = deadline
  fields.needs_immediate_resume = fields.needs_immediate_resume == true
  self._next_deadline = deadline
  return public_status(self, fields)
end

---Advance the application within one host-controlled execution horizon.
---
---`opts.horizon` is an absolute value in the host clock domain. Alternatively,
---`opts.max_seconds` supplies a relative horizon. `max_steps` bounds runtime
---driver calls and `max_work` is the resumable proof quantum for each call.
---
---The returned status reports `state = "settled"` or `state = "pending"`.
---Host horizon and turn-budget exhaustion set `needs_immediate_resume = true`;
---a future deadline or external wait does not.
function Application:advance(opts)
  if self._closed then
    error('cannot advance a closed embedded application', 2)
  end
  if self._settled then
    return public_status(self, {
      state = 'settled',
      reason = 'complete',
      runtime_status = self._status and self._status.runtime_status,
      needs_immediate_resume = false,
    })
  end
  if self._advancing then
    error('embedded Application:advance is not re-entrant', 2)
  end

  local max_steps, max_work, max_external, horizon = advance_limits(self, opts)
  self._advancing = true
  if type(self.host.consume_wake) == 'function' then self.host:consume_wake('advance') end

  local external_count = 0
  local ok_external, external_or_error = Protected.pcall(function()
    if type(self.host._drain_external) == 'function' then
      return self.host:_drain_external(max_external)
    end
    return 0
  end)
  if not ok_external then
    self._advancing = false
    return self:_complete(nil, external_or_error)
  end
  external_count = external_or_error or 0
  if external_count > 0 then
    if type(self.host.consume_wake) == 'function' then self.host:consume_wake('external') end
  end

  local last_status
  for step = 1, max_steps do
    local ok, status = Protected.pcall(function()
      return self.runtime:step({ max_work = max_work })
    end)
    if not ok then
      self._advancing = false
      return self:_complete(last_status, status)
    end
    last_status = status

    if status and status.tag == 'idle' then
      self._advancing = false
      return self:_complete(status)
    end

    local ready = runtime_has_ready(self.runtime)
    if status and status.tag == 'quiescent' and not ready then
      self._advancing = false
      return self:_complete(status)
    end

    local hard_capacity = status
      and status.kind == 'budget'
      and (
        status.reason == 'search_total_limit'
        or status.reason == 'search_depth_limit'
        or status.reason == 'search_trail_limit'
      )
    if hard_capacity and not ready then
      self._advancing = false
      return pending_turn(self, 'proof-capacity', status, {
        needs_immediate_resume = false,
        steps = step,
        external_deliveries = external_count,
        capacity_reason = status.reason,
      })
    end

    local immediate = ready
      or status
        and (status.tag == 'found' or status.kind == 'budget' or status.kind == 'started' or status.kind == 'no-ready-work' or status.interests_incomplete == true)

    if status and status.tag == 'pending' and status.kind == 'wakeup' then
      local deadline, interests = earliest_deadline(status)
      local unsupported, unsupported_reason = unsupported_interest(self, interests)
      if unsupported and not ready then
        self._advancing = false
        return pending_turn(self, 'unsupported-interest', status, {
          unsupported_interest = unsupported,
          unsupported_reason = unsupported_reason,
          needs_immediate_resume = false,
          steps = step,
          external_deliveries = external_count,
        })
      end
      if ready then
        immediate = true
      elseif type(self.host.has_external) == 'function' and self.host:has_external() then
        local ok_more, delivered = Protected.pcall(function()
          return self.host:_drain_external(max_external - external_count)
        end)
        if not ok_more then
          self._advancing = false
          return self:_complete(status, delivered)
        end
        external_count = external_count + (delivered or 0)
        if (delivered or 0) > 0 then
          if type(self.host.consume_wake) == 'function' then self.host:consume_wake('external') end
        end
        immediate = (delivered or 0) > 0
      elseif deadline ~= nil and deadline <= self:now() then
        immediate = true
      else
        self._advancing = false
        return pending_turn(self, 'wakeup', status, {
          needs_immediate_resume = false,
          steps = step,
          external_deliveries = external_count,
        })
      end
    end

    if self:now() >= horizon then
      self._advancing = false
      return pending_turn(self, 'horizon', status, {
        needs_immediate_resume = true,
        steps = step,
        external_deliveries = external_count,
        horizon = horizon,
      })
    end

    if not immediate then
      self._advancing = false
      return pending_turn(self, 'driver-yield', status, {
        needs_immediate_resume = true,
        steps = step,
        external_deliveries = external_count,
      })
    end
  end

  self._advancing = false
  return pending_turn(self, 'turn-budget', last_status, {
    needs_immediate_resume = true,
    steps = max_steps,
    external_deliveries = external_count,
    horizon = horizon,
  })
end


function Application:close()
  if self._closed then return true end
  if type(self._detach_scheduler) == 'function' then self:_detach_scheduler() end
  self._closed = true
  if self._owns_host and type(self.host.close) == 'function' then
    self.host:close()
  end
  return true
end

return Application
