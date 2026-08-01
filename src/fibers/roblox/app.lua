---Roblox scheduling above the generic embedded Application boundary.

local Base = require('fibers.embed.application')

local Application = {}
Application.__index = Application
setmetatable(Application, { __index = Base })

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

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do out[key] = item end
  return out
end

function Application.new(fn, opts)
  opts = copy(opts)
  local host = opts.host
  if type(host) ~= 'table' or host.kind ~= 'roblox' then
    error('Roblox.prepare requires a fibers.roblox.host host', 2)
  end
  opts.label = 'Roblox.prepare'
  opts.application_marker = '_fibers_roblox_application'
  opts.status_marker = '_fibers_roblox_status'
  local self = Base.new(fn, opts)
  self._attached = false
  self._task = host._task
  self._turn_token = nil
  self._deadline_token = nil
  self._deadline_generation = 0
  self._phase_connection = nil
  self._turn_scheduled = false
  self._reschedule = false
  self._phase_requested = false
  self._scheduling = nil
  self.on_turn_error = opts.on_turn_error
  return setmetatable(self, Application)
end

function Application.is(value)
  return type(value) == 'table' and value._fibers_roblox_application == true
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
  self._task = self.host:require_task()
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

---Wait for an attached application to close.
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

return Application
