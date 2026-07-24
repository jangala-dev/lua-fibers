---A bounded, non-blocking Fibers application embedded in Roblox.
---
---`Application:advance` is the canonical boundary. Roblox or another host loop
---supplies an absolute time horizon and a deterministic step allowance. The
---application advances until it settles, reaches a host-actionable wait, or
---exhausts the current turn. Host horizon exhaustion retains exact proof and
---fibre progress; it is not semantic Retry and cannot enable `or_else`.

local HostHelpers = require('fibers.host')
local Policy = require('fibers.policy')
local Protected = require('fibers.internal.protected')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local ScopeResult = require('fibers.scope.result')

local Application = {}
Application.__index = Application

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function settlement_failures_from(err)
  if type(err) ~= 'table' then
    return {}
  end
  if err._fibers_settlement_failure == true then
    return { err }
  end
  if type(err.cause) == 'table' and err.cause._fibers_settlement_failure == true then
    return { err.cause }
  end
  return {}
end

local function safe_cancel(task_api, token)
  if token ~= nil then
    pcall(task_api.cancel, token)
  end
end

local function safe_disconnect(connection)
  if connection and type(connection.Disconnect) == 'function' then
    pcall(connection.Disconnect, connection)
  end
end

local function positive_integer(value, fallback, name)
  if value == nil then
    return fallback
  end
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    error(name .. ' must be a positive integer', 3)
  end
  value = math.floor(value)
  if value < 1 then
    error(name .. ' must be a positive integer', 3)
  end
  return value
end

local function non_negative_number(value, fallback, name)
  if value == nil then
    return fallback
  end
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge or value < 0 then
    error(name .. ' must be a finite non-negative number', 3)
  end
  return value
end

local function runtime_options(opts, host)
  local out = copy(opts.runtime_options or opts.runtime)
  -- Preserve the established top-level runtime controls for convenience.
  for _, key in ipairs({
    'machine',
    'choice_seed',
    'search_limit',
    'search_total_limit',
    'search_trail_limit',
    'search_depth_limit',
    'cycle_work_limit',
    'cycle_focus_limit',
    'instrumentation',
    'quiet_deadlock',
    'dependency_index',
    'dependency_index_threshold',
    'component_search',
    'normalise_search',
    'branch_policy',
    'certified_symmetry',
    'resumable_search',
  }) do
    if opts[key] ~= nil and out[key] == nil then
      out[key] = opts[key]
    end
  end
  out.host = host
  return out
end

local function public_status(self, fields)
  fields = fields or {}
  fields._fibers_roblox_status = true
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
  local interests = status and (status.interests or status.waits) or {}
  return HostHelpers.earliest_deadline(interests), interests
end

local function unsupported_interest(interests)
  for i = 1, #(interests or {}) do
    local interest = interests[i]
    if interest and interest.kind == 'external' then
      if interest.external_kind == 'readiness' or interest.external_kind == 'poller' then
        return interest
      end
    end
  end
  return nil
end

local function runtime_has_ready(runtime)
  return (runtime._ready_head or 1) <= (runtime._ready_tail or 0)
end

function Application.new(fn, opts)
  opts = opts or {}
  if type(fn) ~= 'function' then
    error('Roblox.prepare expects a root function', 2)
  end
  local host = opts.host
  if type(host) ~= 'table' or host.kind ~= 'roblox' then
    error('Roblox.prepare requires a fibers.host.roblox host', 2)
  end

  local name = opts.name or 'root'
  local runtime = Runtime.new(runtime_options(opts, host))
  local scope = Scope.new(name, {
    runtime = runtime,
    policy = opts.policy or Policy.nursery({ name = name }),
  })

  local self = setmetatable({
    _fibers_roblox_application = true,
    name = name,
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
    _attached = false,
    _owns_host = opts.owns_host ~= false,
    _task = host._task,
    _turn_token = nil,
    _deadline_token = nil,
    _deadline_generation = 0,
    _phase_connection = nil,
    _turn_scheduled = false,
    _reschedule = false,
    _phase_requested = false,
    _next_deadline = nil,
    _scheduling = nil,
    max_steps_per_turn = positive_integer(opts.max_steps_per_turn, 128, 'max_steps_per_turn'),
    max_work_per_step = positive_integer(opts.max_work_per_step, 512, 'max_work_per_step'),
    max_external_per_turn = positive_integer(opts.max_external_per_turn, 4096, 'max_external_per_turn'),
    max_seconds_per_turn = non_negative_number(opts.max_seconds_per_turn, 0.002, 'max_seconds_per_turn'),
    on_status = opts.on_status,
    on_turn_error = opts.on_turn_error,
  }, Application)

  host.application = self
  runtime:spawn_raw(function()
    self._root_result = scope:try_run(fn)
    return self._root_result
  end, name, scope)

  return self
end

function Application.is(value)
  return type(value) == 'table' and value._fibers_roblox_application == true
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
    local settlement_failures = settlement_failures_from(runtime_error)
    result = ScopeResult.fail({
      reason = 'runtime_error',
      primary = runtime_error,
      report = self.scope:_make_report(runtime_error, {}, {
        reason = 'runtime_error',
        settlement_failures = settlement_failures,
      }),
      settlement_failures = settlement_failures,
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
  self:_detach_scheduler()
  self.host:mark_done(result)
  if self._owns_host then
    self.host:close()
  end

  return public_status(self, {
    state = 'settled',
    reason = result.ok and 'complete' or result.reason or 'failed',
    runtime_status = runtime_status,
    needs_immediate_resume = false,
  })
end

local function advance_limits(self, opts)
  opts = opts or {}
  local max_steps =
    positive_integer(opts.max_steps or opts.max_steps_per_turn, self.max_steps_per_turn, 'advance max_steps')
  local max_work =
    positive_integer(opts.max_work or opts.max_work_per_step, self.max_work_per_step, 'advance max_work')
  local max_external = positive_integer(
    opts.max_external or opts.max_external_per_turn,
    self.max_external_per_turn,
    'advance max_external'
  )

  local horizon = opts.horizon
  if horizon ~= nil then
    horizon = tonumber(horizon)
    if not horizon or horizon ~= horizon then
      error('advance horizon must be a number', 3)
    end
  else
    local seconds = non_negative_number(
      opts.max_seconds or opts.max_seconds_per_turn,
      self.max_seconds_per_turn,
      'advance max_seconds'
    )
    horizon = self:now() + seconds
  end
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

---Advance the application within one host-owned execution horizon.
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
    error('cannot advance a closed Roblox application', 2)
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
    error('Roblox Application:advance is not re-entrant', 2)
  end

  local max_steps, max_work, max_external, horizon = advance_limits(self, opts)
  self._advancing = true
  self.host:consume_wake('advance')

  local external_count = 0
  local ok_external, external_or_error = Protected.pcall(function()
    return self.host:_drain_external(max_external)
  end)
  if not ok_external then
    self._advancing = false
    return self:_complete(nil, external_or_error)
  end
  external_count = external_or_error or 0
  if external_count > 0 then
    self.host:consume_wake('external')
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
      local unsupported = unsupported_interest(interests)
      if unsupported and not ready then
        self._advancing = false
        return pending_turn(self, 'unsupported-interest', status, {
          unsupported_interest = unsupported,
          needs_immediate_resume = false,
          steps = step,
          external_deliveries = external_count,
        })
      end
      if ready then
        immediate = true
      elseif self.host:has_external() then
        local ok_more, delivered = Protected.pcall(function()
          return self.host:_drain_external(max_external - external_count)
        end)
        if not ok_more then
          self._advancing = false
          return self:_complete(status, delivered)
        end
        external_count = external_count + (delivered or 0)
        if (delivered or 0) > 0 then
          self.host:consume_wake('external')
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

function Application:_cancel_deadline()
  self._deadline_generation = self._deadline_generation + 1
  safe_cancel(self._task, self._deadline_token)
  self._deadline_token = nil
end

function Application:_schedule_deadline(deadline)
  self:_cancel_deadline()
  if deadline == nil or self._settled or self._closed then
    return
  end
  local generation = self._deadline_generation
  local delay = math.max(0, deadline - self:now())
  self._deadline_token = self._task.delay(delay, function()
    if not self._settled and not self._closed and self._deadline_generation == generation then
      self._deadline_token = nil
      self.host:wake('time')
    end
  end)
end

function Application:_request_event_turn(reason)
  if self._settled or self._closed or not self._attached then
    return false
  end
  if self._scheduling == 'phase' then
    self._phase_requested = true
    return true
  end
  if self._advancing then
    self._reschedule = true
    return true
  end
  self:_cancel_deadline()
  if self._turn_scheduled then
    self._reschedule = true
    return true
  end
  self._turn_scheduled = true
  self._turn_token = self._task.defer(function()
    self._turn_token = nil
    self._turn_scheduled = false
    if self._settled or self._closed or not self._attached then
      return
    end
    local status = self:advance()
    if self._settled then
      return
    end
    if status.needs_immediate_resume or self._reschedule or self.host:has_pending_wake() then
      self._reschedule = false
      self:_request_event_turn(status.reason or reason or 'resume')
    else
      self._reschedule = false
      self:_schedule_deadline(status.next_deadline)
    end
  end)
  return true
end

local function default_run_service()
  local globals = _G
  local data_model = type(globals) == 'table' and rawget(globals, 'game') or nil
  data_model = data_model or game
  if
    (type(data_model) == 'table' or type(data_model) == 'userdata')
    and type(data_model.GetService) == 'function'
  then
    return data_model:GetService('RunService')
  end
  return nil
end

local function resolve_phase(opts)
  local phase = opts.phase
  if type(phase) == 'table' or type(phase) == 'userdata' then
    if type(phase.Connect) ~= 'function' then
      error('Roblox phase value must provide Connect', 3)
    end
    return phase
  end

  local run_service = opts.run_service or default_run_service()
  if type(run_service) ~= 'table' and type(run_service) ~= 'userdata' then
    error('phase scheduling requires RunService or opts.run_service', 3)
  end
  local name = phase or 'Heartbeat'
  local signal = run_service[name]
  if (type(signal) ~= 'table' and type(signal) ~= 'userdata') or type(signal.Connect) ~= 'function' then
    error('RunService phase ' .. tostring(name) .. ' is unavailable', 3)
  end
  return signal
end

function Application:_attach_phase(opts)
  local signal = resolve_phase(opts)
  self._phase_requested = true
  self._phase_connection = signal:Connect(function()
    if self._settled or self._closed or not self._attached then
      return
    end
    -- Defer the actual advance until other handlers at this engine resumption
    -- point have had an opportunity to queue their observations.
    if self._turn_scheduled then
      return
    end
    self._turn_scheduled = true
    self._turn_token = self._task.defer(function()
      self._turn_token = nil
      self._turn_scheduled = false
      if self._settled or self._closed or not self._attached then
        return
      end
      local deadline_due = self._next_deadline ~= nil and self._next_deadline <= self:now()
      if not opts.phase_always and not self._phase_requested and not deadline_due then
        return
      end
      self._phase_requested = false
      local status = self:advance()
      if not self._settled then
        self._next_deadline = status.next_deadline
        if status.needs_immediate_resume or self.host:has_pending_wake() then
          self._phase_requested = true
        end
      end
    end)
  end)
end

---Attach scheduling above the canonical non-blocking `advance` boundary.
---
---`scheduling = "event"` uses coalesced `task.defer` turns and a single
---`task.delay` for the earliest deadline. `scheduling = "phase"` advances at a
---selected RunService phase, still deferring the solver until ordinary signal
---handlers at that resumption point have queued their observations.
function Application:attach(opts)
  opts = opts or {}
  if self._closed then
    error('cannot attach a closed Roblox application', 2)
  end
  if self._attached then
    return self
  end
  local scheduling = opts.scheduling or 'event'
  if scheduling ~= 'event' and scheduling ~= 'phase' then
    error('Roblox scheduling must be "event" or "phase"', 2)
  end
  self._attached = true
  self._scheduling = scheduling

  self.host:set_wake_callback(function(reason)
    return self:_request_event_turn(reason)
  end)

  if self._scheduling == 'phase' then
    self:_attach_phase(opts)
  else
    self:_request_event_turn('initial')
  end
  return self
end

function Application:_detach_scheduler()
  if not self._attached and not self._phase_connection and not self._turn_token then
    return
  end
  self._attached = false
  self.host:set_wake_callback(nil)
  self:_cancel_deadline()
  safe_cancel(self._task, self._turn_token)
  self._turn_token = nil
  self._turn_scheduled = false
  self._reschedule = false
  safe_disconnect(self._phase_connection)
  self._phase_connection = nil
end

function Application:detach()
  self:_detach_scheduler()
  return self
end

---Wait for an attached application to settle.
---
---This is convenience sugar for scripts and `BindToClose`; it does not drive the
---runtime itself. The attached scheduler continues to call `advance`.
function Application:await(timeout)
  local settled, reason = self.host:wait_done(timeout)
  if settled then
    return self._result
  end
  return nil, reason
end

function Application:close()
  if self._closed then
    return true
  end
  self:_detach_scheduler()
  self._closed = true
  if self._owns_host then
    self.host:close()
  end
  return true
end

return Application
