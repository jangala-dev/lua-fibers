-- Pure policy and reporting support for the Happy Eyeballs race.
--
-- Ordering callbacks run while an option is being described, so they receive an
-- isolated copy in stable arrival/current-policy order and must be immediate,
-- deterministic and side-effect free. This module performs no socket, timer or
-- scope effects.

local Address = require('fibers.socket.address')
local HostError = require('fibers.host.error')
local IO = require('fibers.host.io')
local Protected = require('fibers.internal.protected')

local Policy = {}
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
        HostError.protocol('socket', 'happy_eyeballs_order', tostring(address_or_err), {
          endpoint = endpoint,
          family = family,
          index = i,
        })
    end
    local address = address_or_err
    if address.kind ~= family then
      return nil,
        HostError.protocol(
          'socket',
          'happy_eyeballs_order',
          'resolver returned an address from the wrong family',
          {
            endpoint = endpoint,
            expected_family = family,
            actual_family = address.kind,
            index = i,
          }
        )
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
        'happy_eyeballs_order',
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
        HostError.protocol('socket', 'happy_eyeballs_order', tostring(address_or_err), {
          endpoint = endpoint,
          index = i,
        })
    end
    local key = Address.key(address_or_err)
    if not available[key] then
      return nil,
        HostError.protocol(
          'socket',
          'happy_eyeballs_order',
          'ordering callback returned an unknown destination',
          {
            endpoint = endpoint,
            index = i,
            address = address_or_err,
          }
        )
    end
    if used[key] then
      return nil,
        HostError.protocol(
          'socket',
          'happy_eyeballs_order',
          'ordering callback returned a duplicate destination',
          {
            endpoint = endpoint,
            index = i,
            address = address_or_err,
          }
        )
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

local function default_global_order(values)
  local v6, v4 = {}, {}
  for i = 1, #values do
    local target = values[i].kind == 'inet6' and v6 or v4
    target[#target + 1] = values[i]
  end
  local out = {}
  for i = 1, #v6 do
    out[#out + 1] = v6[i]
  end
  for i = 1, #v4 do
    out[#out + 1] = v4[i]
  end
  return out
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
  local global = race.opts.order_destinations
  if global == nil and race.host and type(race.host.sort_destination_addresses) == 'function' then
    global = function(addresses)
      return race.host:sort_destination_addresses(addresses, race.endpoint, race.opts)
    end
  end
  if global ~= nil and global ~= false then
    if type(global) ~= 'function' then
      return nil,
        nil,
        HostError.invalid_argument('socket', 'happy_eyeballs_order', {
          endpoint = race.endpoint,
          message = 'order_destinations must be a function',
        })
    end
    local result, callback_err = call_ordering(global, merged, race.endpoint, race.opts)
    if not result then
      return nil,
        nil,
        HostError.protocol('socket', 'happy_eyeballs_order', tostring(callback_err), {
          endpoint = race.endpoint,
        })
    end
    ordered, err = validate_global_order(result, merged, race.endpoint)
    if not ordered then
      return nil, nil, err
    end
  else
    -- Compatibility hook from the first implementation: sort within each family.
    local sorter = race.opts.sort_addresses
    if sorter ~= nil and sorter ~= false and type(sorter) ~= 'function' then
      return nil,
        nil,
        HostError.invalid_argument('socket', 'happy_eyeballs_order', {
          endpoint = race.endpoint,
          message = 'sort_addresses must be a function',
        })
    end
    local by_family = { inet6 = {}, inet4 = {} }
    for i = 1, #merged do
      by_family[merged[i].kind][#by_family[merged[i].kind] + 1] = merged[i]
    end
    for _, kind in ipairs(FAMILIES) do
      if sorter and #by_family[kind] > 0 then
        local result, callback_err = call_ordering(sorter, by_family[kind], kind, race.endpoint, race.opts)
        if not result then
          return nil,
            nil,
            HostError.protocol('socket', 'happy_eyeballs_order', tostring(callback_err), {
              endpoint = race.endpoint,
              family = kind,
            })
        end
        local checked
        checked, err = validate_global_order(result, by_family[kind], race.endpoint)
        if not checked then
          return nil, nil, err
        end
        by_family[kind] = checked
      end
    end
    ordered = {}
    for _, kind in ipairs(FAMILIES) do
      for i = 1, #by_family[kind] do
        ordered[#ordered + 1] = by_family[kind][i]
      end
    end
    if not sorter then
      ordered = default_global_order(merged)
    end
  end
  return interleave(ordered, race.first_family_count), added, nil, dropped
end

local function attempt_options(race, address, index, scope)
  local opts = race.opts
  local out = IO.copy_table(opts.dial_options)
  out.host = opts.host or out.host
  out.scope = scope
  out.name = table.concat({
    opts.name or 'happy-eyeballs',
    'attempt-' .. tostring(index),
    Address.display(address),
  }, ':')
  for _, key in ipairs({
    'nodelay',
    'capacity',
    'read_capacity',
    'write_capacity',
    'chunk_size',
    'read_chunk_size',
    'write_chunk_size',
  }) do
    if opts[key] ~= nil then
      out[key] = opts[key]
    end
  end
  local local_address = opts.local_address
  if local_address == nil then
    local_address = address.kind == 'inet6' and opts.local_address_inet6 or opts.local_address_inet4
  end
  if local_address ~= nil then
    out.local_address = local_address
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

function Policy.terminal_error(race, state)
  state = state or race.state.value
  local attempts = attempt_records(state)
  if #attempts == 0 then
    local err = state.families.inet6.error or state.families.inet4.error
    if err then
      return HostError.normalise(copy_error_fields(err), {
        domain = 'socket',
        action = 'connect_name',
        endpoint = race.endpoint,
      })
    end
  end
  return HostError.new('connect_failed', {
    domain = 'socket',
    action = 'connect_name',
    code = 'connect_failed',
    message = 'all Happy Eyeballs connection attempts failed',
    endpoint = race.endpoint,
    attempts = attempts,
    candidates_dropped = state.candidates_dropped or 0,
  })
end

function Policy.deadline_error(race, state)
  state = state or race.state.value
  return HostError.system('socket', 'connect_name', 'Happy Eyeballs deadline expired', 'ETIMEDOUT', nil, {
    endpoint = race.endpoint,
    deadline = race.opts.overall_deadline,
    attempts = attempt_records(state),
    candidates_dropped = state.candidates_dropped or 0,
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

function Policy.report(race, status, err, completed_at, state)
  state = state or race.state.value
  assert(type(completed_at) == 'number', 'Happy Eyeballs report requires a committed completion time')
  local report = {
    kind = 'happy_eyeballs_v2',
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

Policy.FAMILIES = FAMILIES
Policy.copy_list = copy_list
Policy.copy_map = copy_map
Policy.copy_error = copy_error_fields
Policy.copy_state = copy_state
Policy.completion_addresses = completion_addresses
Policy.completion_error = completion_error
Policy.active_attempt_count = active_attempt_count
Policy.order_candidates = order_candidates
Policy.attempt_options = attempt_options
Policy.error_summary = error_summary
return Policy
