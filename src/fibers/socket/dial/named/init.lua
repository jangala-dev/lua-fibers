-- Named endpoint dials using the Happy Eyeballs v2 strategy.
--
-- This module contributes one strategy to the shared socket Dial handle.  DNS,
-- staggered numeric attempts and losing-resource closure remain private to the
-- admitted Dial Lifetime.

local Runtime = require('fibers.runtime')
local Resolver = require('fibers.socket.resolver')
local State = require('fibers.socket.dial.named.state')
local Label = require('fibers.internal.label')
local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
local perform = require('fibers.perform')
local Contract = require('fibers.internal.contract')

local RFC_MINIMUM_ATTEMPT_DELAY = 0.010
local DEFAULT_CONNECT_TIMEOUT = 30.0
local DEFAULT_MAXIMUM_CANDIDATES = 64

local function finite_nonnegative(value, fallback, name, level)
  if value == nil then return fallback end
  return Contract.non_negative_number(value, name, level or 3)
end

local function positive_integer(value, fallback, name, level)
  if value == nil then return fallback end
  return Contract.positive_integer(value, name, level or 3)
end

local Named = { name = 'happy_eyeballs_v2' }

local NAMED_OPTIONS = {
  scope = true, host = true, label = Contract.non_empty_string,
  nodelay = Contract.boolean, local_address = true, local_address_inet4 = true,
  local_address_inet6 = true, resolution_delay = true, attempt_delay = true,
  first_family_count = true, maximum_candidates = true, maximum_active_attempts = true,
  attempt_timeout = true, timeout = true, deadline = true, destination_ordering = true,
  order_destinations = Contract.func, resolver = true, resolver_options = Contract.table,
  dns = Contract.boolean, nameservers = Contract.table,
  capacity = Contract.positive_integer, read_capacity = Contract.positive_integer,
  write_capacity = Contract.positive_integer, chunk_size = Contract.positive_integer,
  read_chunk_size = Contract.positive_integer, write_chunk_size = Contract.positive_integer,
}

local function validate_named_contract(opts)
  return Contract.record(opts, NAMED_OPTIONS, 'socket.dial_op options', 3)
end

function Named.normalise_options(opts, endpoint)
  opts = validate_named_contract(opts)
  local out = IO.copy_table(opts)
  out.endpoint = endpoint
  out.resolution_delay = finite_nonnegative(out.resolution_delay, 0.050, 'resolution_delay')
  out.attempt_delay = finite_nonnegative(out.attempt_delay, 0.250, 'attempt_delay')
  if out.attempt_delay < RFC_MINIMUM_ATTEMPT_DELAY then
    error('attempt_delay must be at least 0.010 seconds', 3)
  end
  out.first_family_count = positive_integer(out.first_family_count, 1, 'first_family_count')
  out.maximum_candidates =
    positive_integer(out.maximum_candidates, DEFAULT_MAXIMUM_CANDIDATES, 'maximum_candidates')
  if out.maximum_active_attempts ~= nil then
    out.maximum_active_attempts =
      positive_integer(out.maximum_active_attempts, nil, 'maximum_active_attempts')
  end
  if out.attempt_timeout ~= nil and out.attempt_timeout ~= false then
    out.attempt_timeout = finite_nonnegative(out.attempt_timeout, nil, 'attempt_timeout')
  end
  if out.timeout ~= nil and out.timeout ~= false then
    out.timeout = finite_nonnegative(out.timeout, nil, 'timeout')
  end
  if out.deadline ~= nil then
    out.deadline = finite_nonnegative(out.deadline, nil, 'deadline')
  end
  if out.destination_ordering ~= nil and out.destination_ordering ~= 'stable' then
    error("destination_ordering must be 'stable' when supplied", 3)
  end
  return out
end

local function destination_ordering(opts, host)
  if type(opts.order_destinations) == 'function' then
    return opts.order_destinations, 'application'
  end
  if opts.destination_ordering == 'stable' then
    return nil, 'stable'
  end
  if host and type(host.sort_destination_addresses) == 'function' then
    return function(addresses, endpoint, options)
      return host:sort_destination_addresses(addresses, endpoint, options)
    end, 'host'
  end
  error(
    IOError.unsupported('socket', 'sort_destination_addresses', {
      endpoint = opts.endpoint,
      message = 'Happy Eyeballs requires a host or application destination-ordering policy; '
        .. "set destination_ordering = 'stable' only as an explicit non-RFC fallback",
    }),
    0
  )
end

local function start_options(opts, started_at, host)
  local out = IO.copy_table(opts)
  local function feature(name) return host and type(host.feature) == 'function' and host:feature(name) end
  out.maximum_active_attempts = math.min(
    out.maximum_active_attempts
      or feature('happy_eyeballs_maximum_active_attempts')
      or out.maximum_candidates,
    out.maximum_candidates
  )
  if out.attempt_timeout == false then
    out.attempt_timeout = nil
  elseif out.attempt_timeout == nil then
    out.attempt_timeout = feature('happy_eyeballs_attempt_timeout')
  end
  out.order_destinations, out.destination_ordering = destination_ordering(out, host)

  if out.deadline ~= nil then
    out.overall_deadline = out.deadline
  elseif out.timeout == false then
    out.overall_deadline = nil
  elseif out.timeout ~= nil then
    out.overall_deadline = started_at + out.timeout
  else
    out.overall_deadline = started_at + DEFAULT_CONNECT_TIMEOUT
  end
  return out
end

local function resolver_options(dial, driver_scope, opts, host)
  local out = IO.copy_table(opts.resolver_options)
  out.scope = driver_scope
  out.host = host
  out.resolver = opts.resolver or out.resolver
  out.dns = opts.dns ~= nil and opts.dns or out.dns
  out.nameservers = opts.nameservers or out.nameservers
  out.label = Label.describe(dial, dial._fibers_id) .. ':resolve'
  out.family = 'unspec'
  return out
end

function Named.run(dial, driver_scope, opts)
  local rt = Runtime.current()
  local started_at = rt:now()
  local host = opts.host or rt.host
  local strategy_opts = start_options(opts, started_at, host)
  dial.started_at = started_at

  local strategy = State.new(dial._endpoint, strategy_opts, host, started_at)
  local query = perform(
    Resolver.resolve_op(dial._endpoint, resolver_options(dial, driver_scope, strategy_opts, host))
  )

  while true do
    local action = perform(strategy:step_op(query, driver_scope))
    if action.kind == 'winner' then
      return action.winner.connection,
        nil,
        strategy:report('connected', nil, action.completed_at, action.state)
    elseif action.kind == 'failed' or action.kind == 'deadline' then
      local err = action.kind == 'deadline'
          and strategy:deadline_error(action.state)
        or strategy:terminal_error(action.state)
      return nil, err, strategy:report('failed', err, action.completed_at, action.state)
    end
  end
end

function Named.terminal_report(dial, status, err, completed_at)
  local started_at = dial.started_at or completed_at
  return {
    kind = 'dial',
    strategy = 'happy_eyeballs_v2',
    status = status,
    endpoint = dial._endpoint,
    started_at = started_at,
    completed_at = completed_at,
    duration = completed_at - started_at,
    error = State.error_summary(err),
    attempts = {},
    families = {},
  }
end

return Named
