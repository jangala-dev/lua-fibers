-- Transactional state machine for Happy Eyeballs v2.
--
-- DNS completions, attempt results, clock observations, capacity claims and Dial
-- admission are composed as options over one Scalar machine. Irreversible socket
-- work remains inside numeric Dial Lifetimes and begins only after commit.

local Op = require('fibers.op')
local Scalar = require('fibers.resource.scalar')
local Counter = require('fibers.resource.counter')
local Clock = require('fibers.resource.clock')
local Address = require('fibers.socket.address')
local Policy = require('fibers.internal.socket.happy_eyeballs_policy')
local DialModule = require('fibers.socket.dial')
local HostError = require('fibers.host.error')

local Race = {}
Race.__index = Race

local Ready, Wait = Scalar.Ready, Scalar.Wait
local FAMILIES = Policy.FAMILIES
local copy_list = Policy.copy_list
local copy_state = Policy.copy_state
local copy_error_fields = Policy.copy_error
local completion_addresses = Policy.completion_addresses
local completion_error = Policy.completion_error
local order_candidates = Policy.order_candidates
local active_attempt_count = Policy.active_attempt_count
local default_clock = Clock.default()

local function now_op()
  return default_clock:now_op()
end

local PublishFamily = Scalar.transition({
  name = 'socket.happy_eyeballs.publish_family',
  mode = 'update',
  accepts_supply = true,
  supplies = 'any',
  step = function(current, payload)
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
  end,
})

local NextAction = Scalar.transition({
  name = 'socket.happy_eyeballs.next_action',
  mode = 'select',
  accepts_supply = false,
  supplies = 'none',
  step = function(current, payload)
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
    })
  end,
})

local AdmitAttempt = Scalar.transition({
  name = 'socket.happy_eyeballs.admit_attempt',
  mode = 'update',
  accepts_supply = true,
  supplies = 'any',
  step = function(current, payload)
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
      completed_at = nil,
      error = nil,
    }
    next_state.attempts[#next_state.attempts + 1] = entry
    next_state.next_attempt = payload.spec.index + 1
    next_state.next_launch_at = payload.spec.started_at + payload.attempt_delay
    return Ready.write(next_state, { kind = 'launched', attempt = entry, state = next_state })
  end,
})

local FinishAttempt = Scalar.transition({
  name = 'socket.happy_eyeballs.finish_attempt',
  mode = 'update',
  accepts_supply = true,
  supplies = 'any',
  step = function(current, payload)
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
  end,
})

function Race.new(endpoint, opts, host, started_at)
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
  local name = opts.name or 'happy-eyeballs'
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
    attempt_slots = Counter.new({
      initial = opts.maximum_active_attempts,
      min = 0,
      max = opts.maximum_active_attempts,
      name = name .. ':attempt-slots',
    }),
    state = Scalar.machine(state, name .. ':race'),
  }, Race)
end

function Race:publish_family_op(family, completion, finished_at)
  return self.state:transition_op(PublishFamily, {
    race = self,
    family = family,
    completion = completion,
    finished_at = finished_at,
  })
end

function Race:_attempt_result_ops(current, scope)
  local options = {}
  for i = 1, #current.attempts do
    local entry = current.attempts[i]
    if entry.status == 'active' then
      local attempt = entry
      local result = attempt.dial:result_op(scope):map(function(connection, err)
        return { connection = connection, error = err }
      end)
      options[#options + 1] = Op.named_all({
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

function Race:_resolution_ops(current, query)
  local options = {}
  for _, family in ipairs(FAMILIES) do
    local kind = family
    if not current.families[kind].done then
      options[#options + 1] = Op.named_all({
        completion = query:family_finished_op(kind),
        finished_at = now_op(),
      }):and_then(function(observed)
        return self:publish_family_op(kind, observed.completion, observed.finished_at)
      end)
    end
  end
  return Op.choice(options)
end

function Race:_action_at_op(scope, now)
  return self.state
    :transition_op(NextAction, {
      now = now,
      deadline = self.opts.overall_deadline,
    })
    :and_then(function(action)
      if action.kind ~= 'launch' then
        return Op.always(action)
      end
      return self.attempt_slots:take_op(1):and_then(function()
        local dial_opts = Policy.attempt_options(self, action.address, action.index, scope)
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

function Race:_next_progress_at(current, now, available_slots)
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

function Race:_progress_op(current, scope, now, available_slots)
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
function Race:step_op(query, scope)
  return Op.guard(function()
    return Op.named_all({
      state = self.state:read_op(),
      available_slots = self.attempt_slots:read_op(),
      now = now_op(),
    }):and_then(function(view)
      local outcomes = self:_attempt_result_ops(view.state, scope)
      local resolutions = self:_resolution_ops(view.state, query)
      local progress = self:_progress_op(view.state, scope, view.now, view.available_slots)
      return outcomes:or_else(resolutions:or_else(progress))
    end)
  end)
end

function Race:snapshot()
  return copy_state(self.state.value)
end

function Race:terminal_error(state)
  return Policy.terminal_error(self, state)
end

function Race:deadline_error(state)
  return Policy.deadline_error(self, state)
end

function Race:report(status, err, completed_at, state)
  return Policy.report(self, status, err, completed_at, state)
end

Race.FAMILIES = FAMILIES
Race.copy_error = copy_error_fields
return Race
