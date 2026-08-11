---A bounded, non-blocking Fibers application embedded in an external host.
---
---`Application:advance` is the canonical boundary. An embedding host loop
---supplies an absolute time horizon and a deterministic step allowance. The
---application advances until it settles, reaches a host-actionable wait, or
---exhausts the current turn. Host horizon exhaustion retains exact proof and
---fiber progress; it is not semantic Retry and cannot enable `or_else`.

local WaitSet = require('fibers.embed.wait_set')
local Protected = require('fibers.protected')
local RootSession = require('fibers.internal.root_session')
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

local function default(value, fallback)
  return value == nil and fallback or value
end

local function runtime_options(opts, host)
  local out = Contract.copy_table(opts.runtime_options, 'Application runtime_options', 3)
  out.host = host
  return out
end

local function public_status(self, fields)
  fields._fibers_embed_status = true
  if self._status_marker then fields[self._status_marker] = true end
  fields.application = self
  fields.runtime = self.runtime
  fields.scope = self.scope
  fields.result = self._result
  if self.on_status then
    self.on_status(fields)
  end
  return fields
end

local function earliest_deadline(status)
  local interests = status.interests or {}
  return WaitSet.build(interests).deadline, interests
end


local function drain_external(self, limit)
  local drain = self.host._drain_external
  if type(drain) ~= 'function' or limit <= 0 then return true, 0 end
  local ok, count = Protected.pcall(drain, self.host, limit)
  count = count or 0
  if ok and count > 0 and type(self.host._consume_wake) == 'function' then self.host:_consume_wake('external') end
  return ok, count
end

local function unsupported_interest(self, interests)
  local supports = self.host.supports_interest
  if type(supports) ~= 'function' then return nil end
  for i = 1, #interests do
    local interest = interests[i]
    local ok, reason = supports(self.host, interest, self)
    if ok == false then
      return interest, reason
    end
  end
  return nil
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
  local runtime, scope = RootSession.create({
    host = host,
    runtime_options = runtime_options(opts, host),
    label = label,
    closure = opts.closure,
  })

  local self = setmetatable({
    _fibers_embed_application = true,
    _status_marker = opts.status_marker,
    host = host,
    runtime = runtime,
    scope = scope,
    _owns_host = opts.owns_host ~= false,
    max_steps_per_turn = default(opts.max_steps_per_turn, 128),
    max_work_per_step = default(opts.max_work_per_step, 512),
    max_external_per_turn = default(opts.max_external_per_turn, 4096),
    max_seconds_per_turn = default(opts.max_seconds_per_turn, 0.002),
    on_status = opts.on_status,
  }, Application)

  if opts.application_marker then self[opts.application_marker] = true end
  self._root_fiber = RootSession.spawn_root(runtime, scope, fn, label, false)
  return self
end

function Application.is(value)
  return type(value) == 'table' and value._fibers_embed_application == true
end

function Application:result()
  return self._result
end

function Application:now()
  return self.runtime:now()
end

function Application:_complete(runtime_status, runtime_error)
  if self._result then
    return public_status(self, {
      state = 'settled',
      reason = 'complete',
      runtime_status = runtime_status or self._result.runtime_status,
      needs_immediate_resume = false,
    })
  end

  local result = RootSession.complete(
    self.runtime, self.scope, self._root_fiber, runtime_status, runtime_error)
  self._result = result
  if type(self._detach_scheduler) == 'function' then self:_detach_scheduler() end
  if type(self.host.mark_done) == 'function' then self.host:mark_done(result) end
  if self._owns_host and type(self.host.close) == 'function' then self.host:close() end

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

local function leave(self, fn, ...)
  self._advancing = false
  return fn(self, ...)
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
  if self._result then
    return public_status(self, {
      state = 'settled',
      reason = 'complete',
      runtime_status = self._result.runtime_status,
      needs_immediate_resume = false,
    })
  end
  if self._advancing then
    error('embedded Application:advance is not re-entrant', 2)
  end

  local max_steps, max_work, max_external, horizon = advance_limits(self, opts)
  self._advancing = true
  if type(self.host._consume_wake) == 'function' then self.host:_consume_wake('advance') end

  local ok_external, external_count = drain_external(self, max_external)
  if not ok_external then
    return leave(self, self._complete, nil, external_count)
  end

  local last_status
  for step = 1, max_steps do
    local ok, status = Protected.pcall(function()
      return self.runtime:step({ max_work = max_work })
    end)
    if not ok then
      return leave(self, self._complete, last_status, status)
    end
    last_status = status

    if status and status.tag == 'idle' then
      return leave(self, self._complete, status)
    end

    local ready = self.runtime:_has_ready()
    if status and status.tag == 'quiescent' and not ready then
      return leave(self, self._complete, status)
    end

    local hard_capacity = status
      and status.kind == 'budget'
      and (
        status.reason == 'search_total_limit'
        or status.reason == 'search_depth_limit'
        or status.reason == 'search_trail_limit'
      )
    if hard_capacity and not ready then
      return leave(self, pending_turn, 'proof-capacity', status, {
        needs_immediate_resume = false,
        steps = step,
        external_deliveries = external_count,
        capacity_reason = status.reason,
      })
    end

    local immediate = ready
      or status
        and (status.tag == 'found' or status.kind == 'budget' or status.kind == 'started' or status.interests_incomplete == true)

    if status and status.tag == 'pending' and status.kind == 'wakeup' then
      local deadline, interests = earliest_deadline(status)
      local unsupported, unsupported_reason = unsupported_interest(self, interests)
      if unsupported and not ready then
        return leave(self, pending_turn, 'unsupported-interest', status, {
          unsupported_interest = unsupported,
          unsupported_reason = unsupported_reason,
          needs_immediate_resume = false,
          steps = step,
          external_deliveries = external_count,
        })
      end
      if ready then
        immediate = true
      else
        local ok_more, delivered = drain_external(self, max_external - external_count)
        if not ok_more then return leave(self, self._complete, status, delivered) end
        external_count = external_count + delivered
        if delivered > 0 or deadline ~= nil and deadline <= self:now() then
          immediate = true
        else
          return leave(self, pending_turn, 'wakeup', status, {
            needs_immediate_resume = false,
            steps = step,
            external_deliveries = external_count,
          })
        end
      end
    end

    if self:now() >= horizon then
      return leave(self, pending_turn, 'horizon', status, {
        needs_immediate_resume = true,
        steps = step,
        external_deliveries = external_count,
        horizon = horizon,
      })
    end

    if not immediate then
      return leave(self, pending_turn, 'driver-yield', status, {
        needs_immediate_resume = true,
        steps = step,
        external_deliveries = external_count,
      })
    end
  end

  return leave(self, pending_turn, 'turn-budget', last_status, {
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
