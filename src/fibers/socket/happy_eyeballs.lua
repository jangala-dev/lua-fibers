-- Happy Eyeballs v2 named stream dials.
--
-- The public handle owns one private driver scope.  The driver composes DNS
-- completions, numeric Dial outcomes, timers and candidate admission through the
-- transactional race machine in fibers.internal.socket.happy_eyeballs_race.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.socket.address')
local ResolverModule = require('fibers.socket.resolver')
local DialLifecycle = require('fibers.socket.dial_lifecycle')
local Race = require('fibers.internal.socket.happy_eyeballs_race')
local HostError = require('fibers.host.error')
local IO = require('fibers.host.io')
local Region = require('fibers.region')
local Owned = require('fibers.region').Owned
local Protected = require('fibers.internal.protected')
local Settlement = require('fibers.region.settlement')
local perform = require('fibers.perform')

local Module = {}
local NamedDial = {}
NamedDial.__index = NamedDial
local next_dial = 0

local RFC_MINIMUM_ATTEMPT_DELAY = 0.010
local DEFAULT_CONNECT_TIMEOUT = 30.0
local DEFAULT_MAXIMUM_CANDIDATES = 64
local DEFAULT_MAXIMUM_ACTIVE_ATTEMPTS = 4

local function finite_nonnegative(value, fallback, name)
  if value == nil then
    return fallback
  end
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge or value < 0 then
    error(name .. ' must be a finite non-negative number', 3)
  end
  return value
end

local function attempt_delay(value)
  value = finite_nonnegative(value, 0.250, 'attempt_delay')
  if value < RFC_MINIMUM_ATTEMPT_DELAY then
    error('attempt_delay must be at least 0.010 seconds', 3)
  end
  return value
end

local function integer_at_least(value, fallback, minimum, name)
  if value == nil then
    return fallback
  end
  value = tonumber(value)
  if not value or value ~= math.floor(value) or value < minimum then
    error(name .. ' must be an integer of at least ' .. tostring(minimum), 3)
  end
  return value
end

local function named_dial_settlement(dial)
  return Settlement.request_then_wait(function(_ctx, _record, reason)
    return dial:close_op(reason or 'scope settlement')
  end, function()
    return dial:closed_op():and_then(function(ok, err)
      if not ok then
        error(err or 'named dial settlement failed', 0)
      end
      return Op.always(true)
    end)
  end)
end

function NamedDial:owned(children)
  return Owned.tree(self, self._fibers_settle, children or {}, {
    role = 'socket_named_dial',
    settle_name = 'socket_named_dial',
  })
end

function NamedDial:state_op()
  return self.lifecycle:state_op()
end

function NamedDial:state_value()
  return self.lifecycle:state_value()
end

local function connected_to_region_op(dial, region)
  return dial.lifecycle:claim_op():and_then(function(connection, source_region)
    return source_region:move_op(connection, region):map(function()
      return connection
    end)
  end)
end

function NamedDial:connected_op(target)
  local dial = self
  return IO.with_target_region_op(
    target,
    'named Dial connection transfer expects a target Scope or Region, or a current Scope',
    function(region)
      return connected_to_region_op(dial, region)
    end
  )
end

function NamedDial:failed_op()
  return self.lifecycle:failure_op()
end

function NamedDial:result_op(target)
  return self:connected_op(target):or_else(self:failed_op():map(function(err)
    return nil, err
  end))
end

function NamedDial:report_op()
  return self.lifecycle:report_op()
end

local function connect_result_to_region_op(dial, region)
  return dial.lifecycle
    :claim_op()
    :and_then(function(connection, source_region, report)
      return source_region:move_op(connection, region):map(function()
        return connection, report
      end)
    end)
    :or_else(dial:failed_op():map(function(err)
      return nil, err
    end))
end

function NamedDial:connect_result_op(target)
  local dial = self
  return IO.with_target_region_op(
    target,
    'named Dial connection transfer expects a target Scope or Region, or a current Scope',
    function(region)
      return connect_result_to_region_op(dial, region)
    end
  )
end

function NamedDial:close_op(reason)
  reason = reason or 'named dial closed'
  local cancel = self.driver and self.driver:request_cancel_op(reason) or Op.always(true)
  return self.lifecycle:request_close_op(reason):and_then(function(first)
    if first and self.driver then
      return cancel:map(function()
        return true
      end)
    end
    return Op.always(true)
  end, cancel)
end

local function closed_result(state)
  if state.fatal and state.error then
    return nil, state.error
  end
  return true
end

function NamedDial:closed_op()
  return Op.named_all({
    driver = self.driver and self.driver:exit_op() or Op.always(true),
    lifecycle = self.lifecycle:terminal_op(),
  }):map(function(result)
    return closed_result(result.lifecycle)
  end)
end

local function copy_error(err)
  return Race.copy_error(err)
end

local function attach_report(err, report)
  local out = copy_error(err)
  if not HostError.is(out) then
    out = HostError.system('socket', 'connect_name', tostring(err), nil, nil)
  end
  out.report = report
  return out
end

local function resolver_options(named_dial, driver_scope, opts, host)
  local out = IO.copy_table(opts.resolver_options)
  out.owner = driver_scope
  out.host = host
  out.resolver = opts.resolver or out.resolver
  out.dns = opts.dns ~= nil and opts.dns or out.dns
  out.nameservers = opts.nameservers or out.nameservers
  out.nameserver = opts.nameserver or out.nameserver
  out.name = named_dial.name .. ':resolve'
  out.family = 'unspec'
  out.require_nonblocking = opts.require_nonblocking
  return out
end

local function prepare_options(opts, started_at)
  local out = IO.copy_table(opts)
  out.resolution_delay = finite_nonnegative(out.resolution_delay, 0.050, 'resolution_delay')
  out.attempt_delay = attempt_delay(out.attempt_delay)
  out.first_family_count = integer_at_least(out.first_family_count, 1, 1, 'first_family_count')
  out.maximum_candidates =
    integer_at_least(out.maximum_candidates, DEFAULT_MAXIMUM_CANDIDATES, 1, 'maximum_candidates')
  out.maximum_active_attempts = integer_at_least(
    out.maximum_active_attempts,
    DEFAULT_MAXIMUM_ACTIVE_ATTEMPTS,
    1,
    'maximum_active_attempts'
  )

  if out.deadline ~= nil then
    out.overall_deadline = out.deadline
  elseif out.timeout == false then
    out.overall_deadline = nil
  elseif out.timeout ~= nil then
    out.overall_deadline = started_at + finite_nonnegative(out.timeout, 0, 'timeout')
  elseif out.default_connect_timeout ~= false then
    out.overall_deadline = started_at
      + finite_nonnegative(out.default_connect_timeout, DEFAULT_CONNECT_TIMEOUT, 'default_connect_timeout')
  end
  if out.overall_deadline ~= nil then
    out.overall_deadline = finite_nonnegative(out.overall_deadline, 0, 'deadline')
  end
  return out
end

local function run_race(named_dial, driver_scope, opts)
  local rt = Runtime.current()
  local started_at = rt:now()
  local race_opts = prepare_options(opts, started_at)
  local host = race_opts.host or rt.host
  named_dial.started_at = started_at

  local race = Race.new(named_dial.endpoint, race_opts, host, started_at)
  local query = perform(
    ResolverModule.resolve_op(
      named_dial.endpoint,
      resolver_options(named_dial, driver_scope, race_opts, host)
    )
  )

  while true do
    local action = perform(race:step_op(query, driver_scope))
    if action.kind == 'winner' then
      return action.winner.connection, nil, race:report('connected', nil, action.completed_at, action.state)
    elseif action.kind == 'failed' then
      local err = race:terminal_error(action.state)
      local report = race:report('failed', err, action.completed_at, action.state)
      return nil, attach_report(err, report), report
    elseif action.kind == 'deadline' then
      local err = race:deadline_error(action.state)
      local report = race:report('failed', err, action.completed_at, action.state)
      return nil, attach_report(err, report), report
    end
    -- resolution, attempt_failed and launched are committed progress events;
    -- the next algebraic step derives the only currently permitted action.
  end
end

local function cancellation_report(named_dial, err)
  local now = Runtime.current():now()
  return {
    kind = 'happy_eyeballs_v2',
    status = 'cancelled',
    endpoint = named_dial.endpoint,
    started_at = named_dial.started_at,
    completed_at = now,
    duration = now - named_dial.started_at,
    error = {
      kind = err.kind,
      domain = err.domain,
      action = err.action,
      code = err.code,
      message = err.message,
    },
    attempts = {},
    families = {},
  }
end

local function driver(named_dial, driver_scope, opts)
  local rt = Runtime.current()
  local ok, connection, err, report = Protected.pcall(run_race, named_dial, driver_scope, opts)
  if not ok then
    local thrown = connection
    if Runtime.is_cancelled(thrown) then
      local closed = HostError.closed('socket', 'connect_name', {
        reason = thrown.reason or 'Happy Eyeballs cancelled',
        endpoint = named_dial.endpoint,
      })
      local cancelled = cancellation_report(named_dial, closed)
      IO.masked_perform(
        rt,
        named_dial.lifecycle:closed_op(thrown.reason or 'Happy Eyeballs cancelled', closed, false, cancelled)
      )
      return
    end

    local fatal = not HostError.is(thrown)
    local failure = fatal
        and IO.protocol_error('socket', 'happy_eyeballs_driver', thrown, {
          endpoint = named_dial.endpoint,
        })
      or copy_error(thrown)
    local failure_report = cancellation_report(named_dial, failure)
    failure_report.status = 'failed'
    failure = attach_report(failure, failure_report)
    IO.masked_perform(rt, named_dial.lifecycle:publish_failure_op(failure, fatal, failure_report))
    return
  end

  if not connection then
    IO.masked_perform(rt, named_dial.lifecycle:publish_failure_op(err, false, report))
    return
  end

  local driver_region = IO.region_of(driver_scope)
  local published, state =
    IO.masked_perform(rt, named_dial.lifecycle:publish_connected_op(connection, driver_region, report))
  if not published then
    if state.kind == 'closing' or state.kind == 'closed' then
      return
    end
    error(
      HostError.protocol(
        'socket',
        'publish_connected',
        'named Dial lifecycle rejected a connection',
        { endpoint = named_dial.endpoint, state = state.kind }
      ),
      0
    )
  end

  -- Keep the private scope, and therefore an unclaimed winning Stream, alive
  -- until the caller moves the connection out or closes the named Dial.
  perform(named_dial.lifecycle:driver_release_op())
end

function Module.dial_op(endpoint, opts)
  opts = IO.copy_table(opts)
  endpoint = Address.validate(endpoint, 'socket.dial_name_op')
  if not Address.is_name(endpoint) then
    error('socket.dial_name_op expects a name endpoint', 2)
  end
  local owner = IO.current_owner(opts, 'socket.dial_name_op')
  next_dial = next_dial + 1
  local name = opts.name or ('named-dial-' .. tostring(next_dial))
  local rt = Runtime.current()
  if opts.timeout ~= nil and opts.timeout ~= false then
    opts.timeout = finite_nonnegative(opts.timeout, 0, 'timeout')
  end
  if opts.attempt_delay ~= nil then
    opts.attempt_delay = attempt_delay(opts.attempt_delay)
  end
  if opts.default_connect_timeout ~= nil and opts.default_connect_timeout ~= false then
    opts.default_connect_timeout =
      finite_nonnegative(opts.default_connect_timeout, DEFAULT_CONNECT_TIMEOUT, 'default_connect_timeout')
  end
  if opts.maximum_candidates ~= nil then
    opts.maximum_candidates =
      integer_at_least(opts.maximum_candidates, DEFAULT_MAXIMUM_CANDIDATES, 1, 'maximum_candidates')
  end
  if opts.maximum_active_attempts ~= nil then
    opts.maximum_active_attempts = integer_at_least(
      opts.maximum_active_attempts,
      DEFAULT_MAXIMUM_ACTIVE_ATTEMPTS,
      1,
      'maximum_active_attempts'
    )
  end

  local dial = Region.handle(name, {
    kind = 'socket_named_dial',
    endpoint = endpoint,
    scope_owner = owner,
    lifecycle = DialLifecycle.new(name, endpoint),
    driver = nil,
    started_at = rt and rt:now() or 0,
  })
  setmetatable(dial, NamedDial)
  dial._fibers_settle = named_dial_settlement(dial)
  dial._fibers_settle_name = 'socket_named_dial'

  local driver_parent = IO.scope_for_owner(owner, 'socket.dial_name_op')
  dial.driver = IO.new_driver_task(driver_parent, name .. ':driver', function(driver_scope)
    return driver(dial, driver_scope, opts)
  end)

  return owner
    :admit_op(dial:owned({ dial.driver:owned() }))
    :and_then(function()
      return dial.driver:spawn_effect_op()
    end, false)
    :map(function()
      return dial
    end)
end

function NamedDial:connected(target)
  return perform(self:connected_op(target))
end

function NamedDial:failed()
  return perform(self:failed_op())
end

function NamedDial:result(target)
  return perform(self:result_op(target))
end

function NamedDial:connect_result(target)
  return perform(self:connect_result_op(target))
end

-- Strong performing convenience: the winning Stream has moved to the target and
-- every resolver query, losing Dial and losing Stream in the private race scope
-- has settled before this method returns.
function NamedDial:connect(target)
  local connection, result = self:connect_result(target)
  local closed, close_err = self:closed()
  if not closed then
    if connection and type(connection.abort) == 'function' then
      Protected.pcall(connection.abort, connection, close_err or 'named Dial settlement failed')
    end
    return nil, close_err
  end
  return connection, result
end

function NamedDial:report()
  return perform(self:report_op())
end

function NamedDial:close(reason)
  return perform(self:close_op(reason))
end

function NamedDial:closed()
  return perform(self:closed_op())
end

Module.NamedDial = NamedDial
return Module
