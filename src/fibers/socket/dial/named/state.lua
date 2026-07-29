-- Transactional state for the named-dial Happy Eyeballs v2 strategy.
--
-- DNS completions, attempt results, clock observations, capacity claims and Dial
-- admission are composed as options over one Cell machine. Irreversible socket
-- work remains inside numeric Dial Lifetimes and begins only after commit.

local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local Counter = require('fibers.resource.counter')
local Clock = require('fibers.resource.clock')
local Address = require('fibers.socket.address')
local IO = require('fibers.host.io')
local Protected = require('fibers.protected')
local DialModule = require('fibers.socket.dial')
local Connection = require('fibers.socket.connection')
local HostError = require('fibers.host.error')

local State = {}
State.__index = State

local Ready, Wait = StateMachine.Ready, StateMachine.Wait
local FAMILIES = { 'inet6', 'inet4' }

local function copy_list(values)
  local out = {}
  for i = 1, #(values or {}) do
    out[i] = values[i]
  end
  return out
end

local function copy_map(values)
  local out = {}
  for key, value in pairs(values or {}) do
    out[key] = value
  end
  return out
end

local function copy_error_fields(err)
  if not HostError.is(err) then
    return err
  end
  local fields = {}
  for key, value in pairs(err) do
    if key ~= '_fibers_host_error' and key ~= 'report' then
      fields[key] = value
    end
  end
  return HostError.new(err.kind, fields)
end

local function copy_family(info)
  return {
    done = info.done == true,
    addresses = copy_list(info.addresses),
    error = info.error,
    finished_at = info.finished_at,
  }
end

local function copy_attempt(entry)
  return {
    index = entry.index,
    family = entry.family,
    address = entry.address,
    key = entry.key,
    dial = entry.dial,
    status = entry.status,
    started_at = entry.started_at,
    deadline = entry.deadline,
    completed_at = entry.completed_at,
    error = entry.error,
  }
end

local function copy_state(current)
  local out = {
    families = {
      inet6 = copy_family(current.families.inet6),
      inet4 = copy_family(current.families.inet4),
    },
    unattempted = copy_list(current.unattempted),
    seen = copy_map(current.seen),
    attempts = {},
    next_attempt = current.next_attempt,
    next_launch_at = current.next_launch_at,
    resolution_deadline = current.resolution_deadline,
    winner = current.winner,
    candidates_dropped = current.candidates_dropped or 0,
  }
  for i = 1, #current.attempts do
    out.attempts[i] = copy_attempt(current.attempts[i])
  end
  return out
end

local function active_attempt_count(state)
  local count = 0
  for i = 1, #(state.attempts or {}) do
    if state.attempts[i].status == 'active' then
      count = count + 1
    end
  end
  return count
end

local function completion_addresses(state)
  if type(state) ~= 'table' or state.kind ~= 'succeeded' then
    return nil
  end
  local values = state.values
  return values and values[1] or state.value
end

local function completion_error(state)
  if type(state) ~= 'table' then
    return nil
  end
  if state.kind == 'failed' then
    return state.error
  end
  if state.kind == 'cancelled' then
    return state.reason
  end
  return nil
end

local function validate_addresses(values, family, endpoint)
  local out, seen = {}, {}
  for i = 1, #(values or {}) do
    local ok, address_or_err = Protected.pcall(Address.validate, values[i], 'Happy Eyeballs candidate')
    if not ok then
      return nil,
        HostError.protocol('socket', 'dial_order', tostring(address_or_err), {
          endpoint = endpoint,
          family = family,
          index = i,
        })
    end
    local address = address_or_err
    if address.kind ~= family then
      return nil,
        HostError.protocol('socket', 'dial_order', 'resolver returned an address from the wrong family', {
          endpoint = endpoint,
          expected_family = family,
          actual_family = address.kind,
          index = i,
        })
    end
    local key = Address.key(address)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = address
    end
  end
  return out
end

local function validate_global_order(values, expected, endpoint)
  if type(values) ~= 'table' then
    return nil,
      HostError.protocol(
        'socket',
        'dial_order',
        'order_destinations must return an address list',
        { endpoint = endpoint }
      )
  end
  local available, out, used = {}, {}, {}
  for i = 1, #expected do
    available[Address.key(expected[i])] = expected[i]
  end
  for i = 1, #values do
    local ok, address_or_err = Protected.pcall(Address.validate, values[i], 'ordered destination')
    if not ok then
      return nil,
        HostError.protocol('socket', 'dial_order', tostring(address_or_err), {
          endpoint = endpoint,
          index = i,
        })
    end
    local key = Address.key(address_or_err)
    if not available[key] then
      return nil,
        HostError.protocol('socket', 'dial_order', 'ordering callback returned an unknown destination', {
          endpoint = endpoint,
          index = i,
          address = address_or_err,
        })
    end
    if used[key] then
      return nil,
        HostError.protocol('socket', 'dial_order', 'ordering callback returned a duplicate destination', {
          endpoint = endpoint,
          index = i,
          address = address_or_err,
        })
    end
    used[key] = true
    out[#out + 1] = available[key]
  end
  -- A policy may rank only part of the set; retain every omitted destination in
  -- stable input order rather than silently dropping a usable address.
  for i = 1, #expected do
    local key = Address.key(expected[i])
    if not used[key] then
      out[#out + 1] = expected[i]
    end
  end
  return out
end

local function interleave(ordered, first_family_count)
  if #ordered <= 1 then
    return ordered
  end
  local preferred = ordered[1].kind
  local alternate = preferred == 'inet6' and 'inet4' or 'inet6'
  local by_family = { inet6 = {}, inet4 = {} }
  for i = 1, #ordered do
    local family = ordered[i].kind
    if by_family[family] then
      by_family[family][#by_family[family] + 1] = ordered[i]
    end
  end
  local positions = { inet6 = 1, inet4 = 1 }
  local result = {}
  local function take(family, count)
    for _ = 1, count do
      local value = by_family[family][positions[family]]
      if not value then
        return
      end
      result[#result + 1] = value
      positions[family] = positions[family] + 1
    end
  end
  take(preferred, first_family_count)
  while #result < #ordered do
    local before = #result
    take(alternate, 1)
    take(preferred, 1)
    if #result == before then
      break
    end
  end
  return result
end

local function call_ordering(callback, values, ...)
  local ok, result = Protected.pcall(callback, copy_list(values), ...)
  if not ok then
    return nil, result
  end
  if type(result) ~= 'table' then
    return nil, 'ordering callback must return an address list'
  end
  return result
end

local function order_candidates(race, current, family, values)
  local incoming, err = validate_addresses(values, family, race.endpoint)
  if not incoming then
    return nil, nil, err
  end
  local merged, known = copy_list(current.unattempted), copy_map(current.seen)
  local added, dropped = {}, 0
  local retained = 0
  for _ in pairs(known) do
    retained = retained + 1
  end
  local other = family == 'inet6' and 'inet4' or 'inet6'
  local reserve_other = not current.families[other].done and #current.families[other].addresses == 0
  local limit = race.maximum_candidates - (reserve_other and 1 or 0)
  limit = math.max(0, limit)
  for i = 1, #incoming do
    local address = incoming[i]
    local key = Address.key(address)
    if not known[key] then
      if retained < limit then
        retained = retained + 1
        known[key] = true
        merged[#merged + 1] = address
        added[#added + 1] = address
      else
        dropped = dropped + 1
      end
    end
  end

  local ordered
  if race.destination_ordering == 'application' or race.destination_ordering == 'host' then
    local result, callback_err = call_ordering(race.order_destinations, merged, race.endpoint, race.opts)
    if not result then
      return nil,
        nil,
        HostError.protocol('socket', 'dial_order', tostring(callback_err), {
          endpoint = race.endpoint,
          ordering = race.destination_ordering,
        })
    end
    ordered, err = validate_global_order(result, merged, race.endpoint)
    if not ordered then
      return nil, nil, err
    end
  else
    -- Explicit portable fallback: preserve stable arrival/current-policy order.
    -- The coordinator no longer guesses that IPv6 should globally precede IPv4.
    ordered = copy_list(merged)
  end
  return interleave(ordered, race.first_family_count), added, nil, dropped
end

local function attempt_options(race, spec, scope)
  local address, index = spec.address, spec.index
  local opts = race.opts
  local out = Connection.options(opts)
  out.host = opts.host or out.host
  out.scope = scope
  out.name = table.concat({
    opts.name or 'dial',
    'attempt-' .. tostring(index),
    Address.display(address),
  }, ':')
  local local_address = opts.local_address
  if local_address == nil then
    local_address = address.kind == 'inet6' and opts.local_address_inet6 or opts.local_address_inet4
  end
  if local_address ~= nil then
    out.local_address = local_address
  end
  if spec.deadline ~= nil then
    out.connect_deadline = spec.deadline
  end
  return out
end

local function attempt_record(entry)
  return {
    index = entry.index,
    address = entry.address,
    family = entry.family,
    status = entry.status,
    error = copy_error_fields(entry.error),
    started_at = entry.started_at,
    deadline = entry.deadline,
    completed_at = entry.completed_at,
  }
end

local function attempt_records(state)
  local attempts = {}
  for i = 1, #state.attempts do
    attempts[i] = attempt_record(state.attempts[i])
  end
  return attempts
end

local default_clock = Clock.default()
local unpack_ = table.unpack or unpack

local function now_op()
  return default_clock:now_op()
end

local PublishFamily = StateMachine.update('socket.dial.named.publish_family', function(current, payload)
  if current.families[payload.family].done then
    return Ready.same({ kind = 'ignored', family = payload.family })
  end

  local values = completion_addresses(payload.completion) or {}
  local completion_err = completion_error(payload.completion)
  local ordered, added, order_err, dropped = order_candidates(payload.race, current, payload.family, values)
  if not ordered then
    ordered, added, dropped = copy_list(current.unattempted), {}, 0
  end

  local next_state = copy_state(current)
  local info = next_state.families[payload.family]
  info.done = true
  info.finished_at = payload.finished_at
  info.error = order_err or completion_err
  for i = 1, #added do
    local address = added[i]
    info.addresses[#info.addresses + 1] = address
    next_state.seen[Address.key(address)] = true
  end
  next_state.unattempted = copy_list(ordered)
  next_state.candidates_dropped = next_state.candidates_dropped + (dropped or 0)
  if
    payload.family == 'inet4'
    and #added > 0
    and not next_state.families.inet6.done
    and #next_state.attempts == 0
  then
    next_state.resolution_deadline = payload.finished_at + payload.race.resolution_delay
  end
  return Ready.write(next_state, {
    kind = 'resolution',
    family = payload.family,
    state = next_state,
  })
end)

local NextAction = StateMachine.isolated_select('socket.dial.named.next_action', function(current, payload)
  if current.winner then
    return Ready.same({
      kind = 'winner',
      winner = current.winner,
      state = current,
      completed_at = current.winner.completed_at,
    })
  end

  local active = active_attempt_count(current)
  local closed = current.families.inet6.done and current.families.inet4.done
  if closed and #current.unattempted == 0 and active == 0 then
    return Ready.same({ kind = 'failed', state = current, completed_at = payload.now })
  end
  if payload.deadline ~= nil and payload.now >= payload.deadline then
    return Ready.same({ kind = 'deadline', state = current, completed_at = payload.now })
  end

  local candidate = current.unattempted[1]
  if not candidate then
    return Wait
  end
  if
    #current.attempts == 0
    and candidate.kind == 'inet4'
    and not current.families.inet6.done
    and current.resolution_deadline ~= nil
    and payload.now < current.resolution_deadline
  then
    return Wait
  end
  if active > 0 and current.next_launch_at ~= nil and payload.now < current.next_launch_at then
    return Wait
  end
  return Ready.same({
    kind = 'launch',
    index = current.next_attempt,
    address = candidate,
    key = Address.key(candidate),
    started_at = payload.now,
    deadline = payload.attempt_timeout and (payload.now + payload.attempt_timeout) or nil,
  })
end)

local AdmitAttempt = StateMachine.update('socket.dial.named.admit_attempt', function(current, payload)
  if current.winner then
    return Wait
  end
  local candidate = current.unattempted[1]
  if not candidate or Address.key(candidate) ~= payload.spec.key then
    return Wait
  end
  local next_state = copy_state(current)
  table.remove(next_state.unattempted, 1)
  local entry = {
    index = payload.spec.index,
    family = candidate.kind,
    address = candidate,
    key = payload.spec.key,
    dial = payload.dial,
    status = 'active',
    started_at = payload.spec.started_at,
    deadline = payload.spec.deadline,
    completed_at = nil,
    error = nil,
  }
  next_state.attempts[#next_state.attempts + 1] = entry
  next_state.next_attempt = payload.spec.index + 1
  next_state.next_launch_at = payload.spec.started_at + payload.attempt_delay
  return Ready.write(next_state, { kind = 'launched', attempt = entry, state = next_state })
end)

local FinishAttempt = StateMachine.update('socket.dial.named.finish_attempt', function(current, payload)
  local position
  for i = 1, #current.attempts do
    if current.attempts[i].index == payload.index and current.attempts[i].status == 'active' then
      position = i
      break
    end
  end
  if not position then
    return Ready.same({ kind = 'ignored', release_slot = false })
  end

  local next_state = copy_state(current)
  local entry = next_state.attempts[position]
  entry.completed_at = payload.completed_at
  if payload.connection then
    entry.status = 'succeeded'
    local winner = {
      entry = entry,
      connection = payload.connection,
      address = entry.address,
      family = entry.family,
      completed_at = payload.completed_at,
    }
    next_state.winner = winner
    return Ready.write(next_state, {
      kind = 'winner',
      winner = winner,
      state = next_state,
      completed_at = payload.completed_at,
      release_slot = true,
    })
  end

  entry.status = 'failed'
  entry.error = payload.error
  -- Immediate failure accelerates the next candidate.
  next_state.next_launch_at = payload.completed_at
  return Ready.write(next_state, {
    kind = 'attempt_failed',
    attempt = entry,
    state = next_state,
    completed_at = payload.completed_at,
    release_slot = true,
  })
end)

function State.new(endpoint, opts, host, started_at)
  local state = {
    families = {
      inet6 = { done = false, addresses = {}, error = nil, finished_at = nil },
      inet4 = { done = false, addresses = {}, error = nil, finished_at = nil },
    },
    unattempted = {},
    seen = {},
    attempts = {},
    next_attempt = 1,
    next_launch_at = nil,
    resolution_deadline = nil,
    winner = nil,
    candidates_dropped = 0,
  }
  local name = opts.name or 'named-dial'
  return setmetatable({
    endpoint = endpoint,
    opts = opts,
    host = host,
    started_at = started_at,
    resolution_delay = opts.resolution_delay,
    attempt_delay = opts.attempt_delay,
    first_family_count = opts.first_family_count,
    maximum_candidates = opts.maximum_candidates,
    maximum_active_attempts = opts.maximum_active_attempts,
    attempt_timeout = opts.attempt_timeout,
    destination_ordering = opts.destination_ordering,
    order_destinations = opts.order_destinations,
    attempt_slots = Counter.bounded(opts.maximum_active_attempts, name .. ':attempt-slots'),
    state = StateMachine.new(state, name .. ':state'),
  }, State)
end

function State:publish_family_op(family, completion, finished_at)
  return self.state:transition_op(PublishFamily, {
    race = self,
    family = family,
    completion = completion,
    finished_at = finished_at,
  })
end

function State:_attempt_result_ops(current, scope)
  local options = {}
  for i = 1, #current.attempts do
    local entry = current.attempts[i]
    if entry.status == 'active' then
      local attempt = entry
      local result = attempt.dial:result_op(scope):map(function(connection, err)
        return { connection = connection, error = err }
      end)
      options[#options + 1] = Op.named_each({
        result = result,
        completed_at = now_op(),
      }):and_then(function(observed)
        local normalised
        if not observed.result.connection then
          normalised = HostError.normalise(copy_error_fields(observed.result.error), {
            domain = 'socket',
            action = 'dial',
            address = attempt.address,
          })
        end
        return self.state
          :transition_op(FinishAttempt, {
            index = attempt.index,
            connection = observed.result.connection,
            error = normalised,
            completed_at = observed.completed_at,
          })
          :and_then(function(event)
            if not event.release_slot then
              return Op.always(event)
            end
            return self.attempt_slots:give_op(1):map(function()
              return event
            end)
          end)
      end)
    end
  end
  return Op.choice(options)
end

function State:_resolution_ops(current, query)
  local options = {}
  for _, family in ipairs(FAMILIES) do
    local kind = family
    if not current.families[kind].done then
      options[#options + 1] = Op.named_each({
        completion = query:family_finished_op(kind),
        finished_at = now_op(),
      }):and_then(function(observed)
        return self:publish_family_op(kind, observed.completion, observed.finished_at)
      end)
    end
  end
  return Op.choice(options)
end

function State:_action_at_op(scope, now)
  return self.state
    :transition_op(NextAction, {
      now = now,
      deadline = self.opts.overall_deadline,
      attempt_timeout = self.attempt_timeout,
    })
    :and_then(function(action)
      if action.kind ~= 'launch' then
        return Op.always(action)
      end
      return self.attempt_slots:take_op(1):and_then(function()
        local dial_opts = attempt_options(self, action, scope)
        return DialModule.dial_op(action.address, dial_opts):and_then(function(dial)
          return self.state:transition_op(AdmitAttempt, {
            spec = action,
            dial = dial,
            attempt_delay = self.attempt_delay,
          })
        end)
      end)
    end)
end

local function earlier(a, b)
  if a == nil then
    return b
  elseif b == nil then
    return a
  end
  return math.min(a, b)
end

function State:_next_progress_at(current, now, available_slots)
  local at = self.opts.overall_deadline
  if current.winner then
    return now
  end
  local active = active_attempt_count(current)
  local closed = current.families.inet6.done and current.families.inet4.done
  if closed and #current.unattempted == 0 and active == 0 then
    return now
  end

  local candidate = current.unattempted[1]
  if candidate and available_slots > 0 then
    local candidate_at = now
    if
      #current.attempts == 0
      and candidate.kind == 'inet4'
      and not current.families.inet6.done
      and current.resolution_deadline ~= nil
      and now < current.resolution_deadline
    then
      candidate_at = current.resolution_deadline
    elseif active > 0 and current.next_launch_at ~= nil and now < current.next_launch_at then
      candidate_at = current.next_launch_at
    end
    at = earlier(at, candidate_at)
  end
  return at
end

function State:_progress_op(current, scope, now, available_slots)
  local at = self:_next_progress_at(current, now, available_slots)
  if at == nil then
    return Op.never()
  end

  local readiness
  if at <= now then
    readiness = Op.always(now)
  else
    readiness = default_clock:at_op(at)
  end

  -- Clock readiness, action selection, capacity claim, Dial admission and the
  -- race-state update form one provisional world. There is no wake-only step.
  return readiness:and_then(function(observed_at)
    return self:_action_at_op(scope, observed_at)
  end)
end

-- One algebraic scheduling step. Ready attempt outcomes have semantic priority
-- over DNS publication, and DNS publication has priority over timers/admission.
function State:step_op(query, scope)
  -- The continuation is data-dependent, but its possible enablers are known
  -- from the committed race state at construction time.  Declaring them keeps
  -- fallback arbitration local to the resolver and active Dial Lifetimes rather
  -- than restoring a runtime-wide positive-before-fallback barrier.
  local dependencies = {
    self.state:read_op(),
    self.attempt_slots:read_op(),
    now_op(),
    query:family_finished_op('inet6'),
    query:family_finished_op('inet4'),
  }
  local snapshot = self.state.value
  for i = 1, #(snapshot.attempts or {}) do
    local attempt = snapshot.attempts[i]
    if attempt.status == 'active' then
      dependencies[#dependencies + 1] = attempt.dial:state_op()
    end
  end
  local footprint = Op.dependencies(unpack_(dependencies))

  return Op.guard(function()
    return Op.named_each({
      state = self.state:read_op(),
      available_slots = self.attempt_slots:read_op(),
      now = now_op(),
    }):and_then(function(view)
      local outcomes = self:_attempt_result_ops(view.state, scope)
      local resolutions = self:_resolution_ops(view.state, query)
      local progress = self:_progress_op(view.state, scope, view.now, view.available_slots)
      return outcomes:or_else(resolutions:or_else(progress))
    end, footprint)
  end, footprint)
end

function State:terminal_error(state)
  local race = self
  state = state or race.state.value
  local attempts = attempt_records(state)
  if #attempts == 0 then
    local err = state.families.inet6.error or state.families.inet4.error
    if err then
      return HostError.normalise(copy_error_fields(err), {
        domain = 'socket',
        action = 'connect',
        endpoint = race.endpoint,
      })
    end
  end
  return HostError.new('connect_failed', {
    domain = 'socket',
    action = 'connect',
    code = 'connect_failed',
    message = 'all Happy Eyeballs connection attempts failed',
    endpoint = race.endpoint,
    attempts = attempts,
    candidates_dropped = state.candidates_dropped or 0,
    unattempted_count = #state.unattempted,
    active_attempts = active_attempt_count(state),
  })
end

function State:deadline_error(state)
  local race = self
  state = state or race.state.value
  return HostError.system('socket', 'connect', 'Happy Eyeballs deadline expired', 'ETIMEDOUT', nil, {
    endpoint = race.endpoint,
    deadline = race.opts.overall_deadline,
    attempts = attempt_records(state),
    candidates_dropped = state.candidates_dropped or 0,
    unattempted_count = #state.unattempted,
    active_attempts = active_attempt_count(state),
    blocked_by_attempt_capacity = #state.unattempted > 0
      and active_attempt_count(state) >= race.maximum_active_attempts,
  })
end

local function error_summary(err)
  if err == nil then
    return nil
  end
  if not HostError.is(err) then
    return { message = tostring(err) }
  end
  return {
    kind = err.kind,
    domain = err.domain,
    action = err.action,
    code = err.code,
    number = err.number,
    message = err.message,
    temporary = err.temporary,
  }
end

function State:report(status, err, completed_at, state)
  local race = self
  state = state or race.state.value
  assert(type(completed_at) == 'number', 'Happy Eyeballs report requires a committed completion time')
  local report = {
    kind = 'dial',
    strategy = 'happy_eyeballs_v2',
    status = status,
    endpoint = race.endpoint,
    started_at = race.started_at,
    completed_at = completed_at,
    duration = completed_at - race.started_at,
    resolution_delay = race.resolution_delay,
    attempt_delay = race.attempt_delay,
    first_family_count = race.first_family_count,
    maximum_candidates = race.maximum_candidates,
    maximum_active_attempts = race.maximum_active_attempts,
    attempt_timeout = race.attempt_timeout,
    capacity_limited = race.maximum_active_attempts < race.maximum_candidates,
    unattempted_count = #state.unattempted,
    active_attempts = active_attempt_count(state),
    blocked_by_attempt_capacity = #state.unattempted > 0
      and active_attempt_count(state) >= race.maximum_active_attempts,
    destination_ordering = race.destination_ordering,
    candidates_dropped = state.candidates_dropped or 0,
    error = error_summary(err),
    attempts = {},
    families = {},
  }
  for _, family in ipairs(FAMILIES) do
    local info = state.families[family]
    report.families[family] = {
      done = info.done,
      addresses = copy_list(info.addresses),
      error = error_summary(info.error),
      finished_at = info.finished_at,
    }
  end
  for i = 1, #state.attempts do
    local entry = state.attempts[i]
    local attempt_status = entry.status
    if attempt_status == 'active' and state.winner then
      attempt_status = 'losing'
    end
    report.attempts[i] = {
      index = entry.index,
      address = entry.address,
      family = entry.family,
      status = attempt_status,
      started_at = entry.started_at,
      deadline = entry.deadline,
      completed_at = entry.completed_at,
      duration = entry.completed_at and (entry.completed_at - entry.started_at) or nil,
      error = error_summary(entry.error),
    }
  end
  if state.winner then
    report.winner = {
      address = state.winner.address,
      family = state.winner.family,
      attempt = state.winner.entry.index,
      completed_at = state.winner.completed_at,
    }
  end
  return report
end

State.error_summary = error_summary
return State
