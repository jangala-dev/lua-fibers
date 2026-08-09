package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local IOAudit = require('fibers.diagnostics.io')
local fibers = require('fibers')
local Sleep = require('fibers.sleep')
local Op = require('fibers.op')
local socket = require('fibers.socket')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.io.error')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

local function close_server(listener, connection)
  if connection then
    connection:close('Happy Eyeballs fixture complete')
  end
  listener:close('Happy Eyeballs fixture complete')
end

-- Dual-stack names begin with IPv6 and transfer only the winning Stream out of
-- the private race scope.
do
  local host = SimulatedHost.new({ sockets = true, resolver_records = {} })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv6('::1', 0))
    local actual = listener:local_address()
    host.resolver_records['dual.test'] = {
      { kind = 'inet6', host = '::1' },
      { kind = 'inet4', host = '127.0.0.1' },
    }
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-v6-server')

    local connection, report = socket.connect(socket.name_endpoint('dual.test', actual.port))
    assert_truthy(connection, tostring(report))
    assert_eq(report.kind, 'dial')
    assert_eq(report.strategy, 'happy_eyeballs_v2')
    assert_eq(report.status, 'connected')
    assert_eq(report.winner.family, 'inet6')
    assert_eq(#report.attempts, 1)
    assert_eq(report.attempts[1].address.port, actual.port)
    assert_eq(report.destination_ordering, 'host')
    assert_eq(report.maximum_active_attempts, report.maximum_candidates)
    assert_eq(report.capacity_limited, false)
    connection:close('Happy Eyeballs client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs IPv6 winner' })
end

-- RFC-conforming operation requires one global destination-ordering policy.
-- Hosts without one fail explicitly; stable resolver order remains available
-- only through a deliberate non-RFC opt-out.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['ordering-required.test'] = { { kind = 'inet4', host = '127.0.0.1' } },
    },
  })
  host.sort_destination_addresses = false

  fibers.run(function()
    local connection, err = socket.connect(socket.name_endpoint('ordering-required.test', 6553))
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'unsupported'))
    assert_eq(err.action, 'sort_destination_addresses')
    assert_eq(err.endpoint.host, 'ordering-required.test')

    local stable_connection, stable_err = socket.connect(socket.name_endpoint('ordering-required.test', 6553), {
      destination_ordering = 'stable',
    })
    assert_eq(stable_connection, nil)
    assert_truthy(HostError.is(stable_err, 'connect_failed'))
    assert_eq(stable_err.report.destination_ordering, 'stable')
  end, { host = host })
end

-- A global destination policy may prefer IPv4.  Both DNS family completions
-- are consumed before admission, so the first family comes from the combined
-- ordering rather than a hard-coded IPv6 preference.
do
  local host = SimulatedHost.new({ sockets = true, resolver_records = {} })
  local result = fibers.try_run(function(scope)
    local listener4 = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener4:local_address().port
    local listener6 = assert(socket.listen_ipv6('::1', port))
    host.resolver_records['ipv4-first.test'] = {
      { kind = 'inet6', host = '::1' },
      { kind = 'inet4', host = '127.0.0.1' },
    }
    local server = scope:spawn(function()
      local connection = assert(listener4:accept())
      connection:close('IPv4-first fixture complete')
      listener4:close('IPv4-first fixture complete')
      listener6:close('IPv4-first fixture complete')
    end):label('happy-eyeballs-v4-first-server')

    local connection, report = socket.connect(socket.name_endpoint('ipv4-first.test', port), {
      order_destinations = function(addresses)
        table.sort(addresses, function(left, right)
          if left.kind ~= right.kind then
            return left.kind == 'inet4'
          end
          return left.host < right.host
        end)
        return addresses
      end,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(report.winner.family, 'inet4')
    assert_eq(#report.attempts, 1)
    connection:close('IPv4-first client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs global destination ordering' })
end

-- An immediate failure accelerates the next family rather than waiting for the
-- connection-attempt delay.
do
  local host = SimulatedHost.new({ sockets = true, resolver_records = {} })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local actual = listener:local_address()
    host.resolver_records['fallback.test'] = {
      { kind = 'inet6', host = '::1' },
      { kind = 'inet4', host = '127.0.0.1' },
    }
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-v4-server')

    local connection, report = socket.connect(socket.name_endpoint('fallback.test', actual.port), {
      attempt_delay = 1.0,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(report.winner.family, 'inet4')
    assert_eq(#report.attempts, 2)
    assert_eq(report.attempts[1].family, 'inet6')
    assert_eq(report.attempts[1].status, 'failed')
    assert_eq(report.attempts[2].family, 'inet4')
    assert_eq(report.attempts[2].started_at, report.attempts[1].completed_at)
    connection:close('Happy Eyeballs client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs accelerated fallback' })
end

local function dynamic_resolution_case(aaaa_delay, resolution_delay, expected_family)
  local host = SimulatedHost.new({ sockets = true, resolver = false })
  local result = fibers.try_run(function(scope)
    local listener4 = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener4:local_address().port
    local listener6 = assert(socket.listen_ipv6('::1', port))

    local expected_listener = expected_family == 'inet4' and listener4 or listener6
    local server = scope:spawn(function()
      local connection = assert(expected_listener:accept())
      connection:close('dynamic Happy Eyeballs fixture complete')
    end):label('happy-eyeballs-expected-server')

    local resolver = {
      resolve = function()
        error('combined resolution is not used by Happy Eyeballs')
      end,
      resolve_family = function(_self, endpoint, family)
        if family == 'inet6' then
          Sleep.sleep(aaaa_delay)
          return { socket.ipv6_address('::1', endpoint.service) }
        end
        return { socket.ipv4_address('127.0.0.1', endpoint.service) }
      end,
    }
    local connection, report = socket.connect(socket.name_endpoint('dynamic.test', port), {
      resolver = resolver,
      resolution_delay = resolution_delay,
      attempt_delay = 0.250,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(report.winner.family, expected_family)
    if expected_family == 'inet4' then
      assert_eq(report.attempts[1].started_at, resolution_delay)
    else
      assert_eq(report.attempts[1].started_at, aaaa_delay)
    end
    connection:close('dynamic Happy Eyeballs client complete')
    listener4:close('race complete')
    listener6:close('race complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'dynamic Happy Eyeballs' })
end

-- If A arrives first, IPv4 waits only for the configured resolution delay.
dynamic_resolution_case(0.050, 0.020, 'inet4')

-- AAAA arriving within the resolution delay starts IPv6 immediately.
dynamic_resolution_case(0.010, 0.050, 'inet6')

-- A late IPv4 candidate is inserted into the live race and begins only when
-- the connection-attempt delay expires while the IPv6 attempt remains pending.
do
  local pending_closed = false
  local dial_factory
  dial_factory = function(host, address, opts)
    if address.kind == 'inet6' then
      local handle = { _connect_pending = true, _connect_complete = false, readiness = {} }
      local readiness_key = {}
      function handle:readiness_key() return readiness_key end
      function handle:bind_runtime(runtime)
        self.runtime = runtime
      end
      function handle:finish_connect()
        return nil, nil, HostError.would_block('socket', 'connect', { address = address })
      end
      function handle:close()
        pending_closed = true
        return true
      end
      return handle
    end

    host.dial_factory = nil
    local handle, err = host:start_dial(address, opts)
    host.dial_factory = dial_factory
    return handle, err
  end

  local host = SimulatedHost.new({ sockets = true, resolver = false, dial_factory = dial_factory })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener:local_address().port
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-stagger-server')
    local resolver = {
      resolve = function()
        error('combined resolution is not used by Happy Eyeballs')
      end,
      resolve_family = function(_self, endpoint, family)
        if family == 'inet4' then
          Sleep.sleep(0.100)
          return { socket.ipv4_address('127.0.0.1', endpoint.service) }
        end
        return { socket.ipv6_address('::1', endpoint.service) }
      end,
    }

    local connection, report = socket.connect(socket.name_endpoint('stagger.test', port), {
      resolver = resolver,
      attempt_delay = 0.250,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(report.winner.family, 'inet4')
    assert_eq(#report.attempts, 2)
    assert_eq(report.attempts[1].family, 'inet6')
    assert_eq(report.attempts[1].started_at, 0)
    assert_eq(report.families.inet4.finished_at, 0.100)
    assert_eq(report.attempts[2].started_at, 0.250)
    assert_eq(pending_closed, true, 'the losing pending socket is closed before connect returns')
    connection:close('stagger client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs staggered attempt' })
end

-- first_family_count permits a bounded run from the initially preferred
-- family before ordinary alternation resumes.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['first-family.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet6', host = '::2' },
        { kind = 'inet4', host = '127.0.0.1' },
      },
    },
  })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener:local_address().port
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-first-family-server')

    local connection, report = socket.connect(socket.name_endpoint('first-family.test', port), {
      first_family_count = 2,
      attempt_delay = 1.0,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(#report.attempts, 3)
    assert_eq(report.attempts[1].family, 'inet6')
    assert_eq(report.attempts[2].family, 'inet6')
    assert_eq(report.attempts[3].family, 'inet4')
    connection:close('first-family client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs first-family count' })
end

-- Destination ordering can be injected without placing socket work in a
-- speculative callback.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['sorted.test'] = {
        { kind = 'inet6', host = '::2' },
        { kind = 'inet6', host = '::1' },
      },
    },
  })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv6('::1', 0))
    local port = listener:local_address().port
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-sorted-server')

    local connection, report = socket.connect(socket.name_endpoint('sorted.test', port), {
      order_destinations = function(addresses)
        table.sort(addresses, function(left, right)
          return left.host < right.host
        end)
        return addresses
      end,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(#report.attempts, 1)
    assert_eq(report.winner.address.host, '::1')
    connection:close('sorted client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs destination ordering' })
end

-- A relative timeout starts when the admitted driver begins, not when an inert
-- dial option is constructed.
do
  local host = SimulatedHost.new({ sockets = true, resolver = false })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener:local_address().port
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-inert-timeout-server')
    local resolver = {
      resolve = function()
        error('combined resolution is not used by Happy Eyeballs')
      end,
      resolve_family = function(_self, endpoint, family)
        if family == 'inet6' then
          return {}
        end
        Sleep.sleep(0.250)
        return { socket.ipv4_address('127.0.0.1', endpoint.service) }
      end,
    }

    local dial_op = socket.dial_op(socket.name_endpoint('inert.test', port), {
      resolver = resolver,
      timeout = 0.500,
    })
    Sleep.sleep(1.000)
    local dial = fibers.perform(dial_op)
    local connection, report = dial:connect()
    assert_truthy(connection, tostring(report))
    assert_eq(report.started_at, 1.000)
    assert_eq(report.winner.family, 'inet4')
    connection:close('inert timeout client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs inert timeout' })
end

-- A connection success ready at the stagger deadline has semantic priority
-- over launching another candidate.  The or_else negative guard prevents the
-- timer branch from admitting an unnecessary IPv4 Dial in the same world.
do
  local dial_calls = 0
  local dial_factory
  dial_factory = function(host, address, opts)
    dial_calls = dial_calls + 1
    host.dial_factory = nil
    local handle, err = host:start_dial(address, opts)
    host.dial_factory = dial_factory
    if not handle or address.kind ~= 'inet6' then
      return handle, err
    end
    handle._connect_pending = true
    handle._connect_complete = false
    handle:clear_writable()
    fibers.spawn(function()
      Sleep.sleep(0.250)
      handle:mark_writable()
    end):label('happy-eyeballs-boundary-readiness')
    function handle:finish_connect()
      self._connect_pending = false
      self._connect_complete = true
      return self, address
    end
    return handle
  end

  local host = SimulatedHost.new({ sockets = true, resolver_records = {}, dial_factory = dial_factory })
  local result = fibers.try_run(function(scope)
    local listener6 = assert(socket.listen_ipv6('::1', 0))
    local port = listener6:local_address().port
    host.resolver_records['boundary.test'] = {
      { kind = 'inet6', host = '::1' },
      { kind = 'inet4', host = '127.0.0.1' },
    }
    local server = scope:spawn(function()
      local connection = assert(listener6:accept())
      connection:close('boundary fixture complete')
      listener6:close('boundary fixture complete')
    end):label('happy-eyeballs-boundary-server')

    local connection, report = socket.connect(socket.name_endpoint('boundary.test', port), {
      attempt_delay = 0.250,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(report.winner.family, 'inet6')
    assert_eq(#report.attempts, 1)
    assert_eq(dial_calls, 1, 'ready success must suppress same-instant launch')
    connection:close('boundary client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs timer boundary' })
end

-- Certified exhaustion reports every failed attempt.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['dead.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet4', host = '127.0.0.1' },
      },
    },
  })
  fibers.run(function()
    local connection, err = socket.connect(socket.name_endpoint('dead.test', 6553), { attempt_delay = 1.0 })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'connect_failed'))
    assert_truthy(err.report)
    assert_eq(err.report.status, 'failed')
    assert_eq(#err.report.attempts, 2)
    assert_eq(err.report.families.inet6.done, true)
    assert_eq(err.report.families.inet4.done, true)
    assert_truthy(err.report.error ~= err, 'report must not contain its owning error')
    assert_eq(err.report.error.report, nil)
  end, { host = host })
end

-- A losing connect option performs no resolver or socket acquisition.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['unused.test'] = { { kind = 'inet4', host = '127.0.0.1' } },
    },
  })
  local resolve_calls, dial_calls = 0, 0
  local base_resolve, base_start_dial = host.resolve, host.start_dial
  host.resolve = function(self, endpoint, opts)
    resolve_calls = resolve_calls + 1
    return base_resolve(self, endpoint, opts)
  end
  host.start_dial = function(self, address, opts)
    dial_calls = dial_calls + 1
    return base_start_dial(self, address, opts)
  end
  fibers.run(function()
    local value = fibers.perform(Op.always('winner'):or_else(socket.dial_op(socket.name_endpoint('unused.test', 80))))
    assert_eq(value, 'winner')
  end, { host = host })
  assert_eq(resolve_calls, 0)
  assert_eq(dial_calls, 0)
end

-- Destination policy receives the resolver's stable order, not an address-key
-- canonicalisation. The callback may use that order as its final tie-break.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['stable-order.test'] = {
        { kind = 'inet6', host = '::2' },
        { kind = 'inet6', host = '::1' },
      },
    },
  })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv6('::1', 0))
    local port = listener:local_address().port
    local observed
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end):label('happy-eyeballs-stable-order-server')

    local connection, report = socket.connect(socket.name_endpoint('stable-order.test', port), {
      order_destinations = function(addresses)
        if not observed or #addresses > #observed then
          observed = {}
          for i = 1, #addresses do
            observed[i] = addresses[i].host
          end
        end
        return addresses
      end,
    })
    assert_truthy(connection, tostring(report))
    assert_eq(observed[1], '::2')
    assert_eq(observed[2], '::1')
    assert_eq(report.attempts[1].address.host, '::2')
    assert_eq(report.winner.address.host, '::1')
    connection:close('stable-order client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs stable ordering input' })
end

-- RFC 8305's absolute 10 millisecond attempt-delay floor is validated before
-- any named Dial is admitted.
do
  local host = SimulatedHost.new({ sockets = true, resolver_records = {} })
  fibers.run(function()
    local ok, err = pcall(socket.dial_op, socket.name_endpoint('invalid-delay.test', 80), {
      attempt_delay = 0.009,
    })
    assert_eq(ok, false)
    assert_truthy(string.find(tostring(err), 'at least 0.010 seconds', 1, true))
  end, { host = host })
end

-- The retained candidate set is bounded and reports discarded destinations.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['candidate-bound.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet6', host = '::2' },
        { kind = 'inet4', host = '127.0.0.1' },
        { kind = 'inet4', host = '127.0.0.2' },
      },
    },
  })
  fibers.run(function()
    local connection, err = socket.connect(socket.name_endpoint('candidate-bound.test', 6553), {
      attempt_delay = 0.010,
      maximum_candidates = 2,
    })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'connect_failed'))
    assert_eq(#err.attempts, 2)
    assert_eq(err.candidates_dropped, 2)
    assert_eq(err.report.candidates_dropped, 2)
    assert_eq(err.report.maximum_candidates, 2)
  end, { host = host })
end

-- A one-candidate cap cannot reserve a second-family slot. Keep the first
-- usable candidate rather than dropping the race while the other family is
-- unresolved.
do
  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['single-candidate.test'] = { { kind = 'inet6', host = '::1' } },
    },
  })
  fibers.run(function()
    local connection, err = socket.connect(socket.name_endpoint('single-candidate.test', 6553), {
      attempt_delay = 0.010,
      maximum_candidates = 1,
    })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'connect_failed'))
    assert_eq(#err.attempts, 1)
    assert_eq(err.candidates_dropped, 0)
  end, { host = host })
end

-- The general profile has no second four-attempt ceiling. Every retained
-- destination may start at its stagger time even while earlier sockets remain
-- black-holed.
do
  local dial_calls, closed = 0, 0
  local function pending_dial(_host, address)
    dial_calls = dial_calls + 1
    local handle = { _connect_pending = true, _connect_complete = false, readiness = {} }
    local readiness_key = {}
    function handle:readiness_key() return readiness_key end
    function handle:bind_runtime(runtime)
      self.runtime = runtime
    end
    function handle:finish_connect()
      return nil, nil, HostError.would_block('socket', 'connect', { address = address })
    end
    function handle:close()
      closed = closed + 1
      return true
    end
    return handle
  end

  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['default-active-bound.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet4', host = '127.0.0.1' },
        { kind = 'inet6', host = '::2' },
        { kind = 'inet4', host = '127.0.0.2' },
        { kind = 'inet6', host = '::3' },
      },
    },
    dial_factory = pending_dial,
  })
  local result = fibers.try_run(function()
    local connection, err = socket.connect(socket.name_endpoint('default-active-bound.test', 443), {
      attempt_delay = 0.010,
      timeout = 0.055,
    })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'system'))
    assert_eq(err.code, 'ETIMEDOUT')
    assert_eq(dial_calls, 5, 'every retained candidate should start before the overall deadline')
    assert_eq(#err.attempts, 5)
    assert_eq(err.report.maximum_active_attempts, err.report.maximum_candidates)
    assert_eq(err.report.capacity_limited, false)
    assert_eq(err.report.unattempted_count, 0)
    assert_eq(err.report.blocked_by_attempt_capacity, false)
    assert_eq(closed, 5)
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs default active attempts' })
end

-- Pending attempts are bounded. The default-connect-timeout option supplies the
-- deadline, and timeout diagnostics contain summaries rather than live Dials.
do
  local dial_calls, closed = 0, 0
  local function pending_dial(_host, address)
    dial_calls = dial_calls + 1
    local handle = { _connect_pending = true, _connect_complete = false, readiness = {} }
    local readiness_key = {}
    function handle:readiness_key() return readiness_key end
    function handle:bind_runtime(runtime)
      self.runtime = runtime
    end
    function handle:finish_connect()
      return nil, nil, HostError.would_block('socket', 'connect', { address = address })
    end
    function handle:close()
      closed = closed + 1
      return true
    end
    return handle
  end

  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['active-bound.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet4', host = '127.0.0.1' },
        { kind = 'inet6', host = '::2' },
        { kind = 'inet4', host = '127.0.0.2' },
      },
    },
    dial_factory = pending_dial,
  })
  local result = fibers.try_run(function()
    local connection, err = socket.connect(socket.name_endpoint('active-bound.test', 443), {
      attempt_delay = 0.010,
      maximum_active_attempts = 2,
      timeout = 0.030,
    })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'system'))
    assert_eq(err.code, 'ETIMEDOUT')
    assert_eq(err.deadline, 0.030)
    assert_eq(#err.attempts, 2)
    assert_eq(dial_calls, 2)
    assert_eq(err.attempts[1].dial, nil)
    assert_eq(err.attempts[2].dial, nil)
    assert_eq(err.report.maximum_active_attempts, 2)
    assert_eq(err.report.capacity_limited, true)
    assert_eq(err.report.unattempted_count, 2)
    assert_eq(err.report.active_attempts, 2)
    assert_eq(err.report.blocked_by_attempt_capacity, true)
    assert_eq(err.blocked_by_attempt_capacity, true)
    assert_eq(closed, 2, 'bounded pending Dials should close before return')
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs active attempt bound' })
end

-- A deliberately bounded host profile can recover liveness by giving each
-- attempt its own absolute deadline. Slots are released after timeout, so later
-- candidates are still admitted even when earlier sockets black-hole.
do
  local dial_calls, closed = 0, 0
  local function pending_dial(_host, address)
    dial_calls = dial_calls + 1
    local handle = { _connect_pending = true, _connect_complete = false, readiness = {} }
    local readiness_key = {}
    function handle:readiness_key() return readiness_key end
    function handle:bind_runtime(runtime)
      self.runtime = runtime
    end
    function handle:finish_connect()
      return nil, nil, HostError.would_block('socket', 'connect', { address = address })
    end
    function handle:close()
      closed = closed + 1
      return true
    end
    return handle
  end

  local host = SimulatedHost.new({
    sockets = true,
    resolver_records = {
      ['attempt-timeout.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet4', host = '127.0.0.1' },
        { kind = 'inet6', host = '::2' },
      },
    },
    dial_factory = pending_dial,
  })
  local result = fibers.try_run(function()
    local connection, err = socket.connect(socket.name_endpoint('attempt-timeout.test', 443), {
      attempt_delay = 0.010,
      maximum_active_attempts = 1,
      attempt_timeout = 0.015,
      timeout = 0.100,
    })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'connect_failed'))
    assert_eq(dial_calls, 3, 'per-attempt deadlines should release the slot for every candidate')
    assert_eq(closed, 3)
    assert_eq(#err.attempts, 3)
    for i = 1, #err.attempts do
      assert_eq(err.attempts[i].status, 'failed')
      assert_eq(err.attempts[i].error.code, 'ETIMEDOUT')
      assert_truthy(err.attempts[i].deadline ~= nil)
    end
    assert_eq(err.report.maximum_active_attempts, 1)
    assert_eq(err.report.attempt_timeout, 0.015)
    assert_eq(err.report.capacity_limited, true)
    assert_eq(err.report.unattempted_count, 0)
    assert_eq(err.report.active_attempts, 0)
    assert_eq(err.report.blocked_by_attempt_capacity, false)
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  IOAudit.assert_clean(result.runtime, { label = 'Happy Eyeballs per-attempt timeout' })
end


-- An explicit top-level dns=false overrides any inherited resolver_options DNS
-- setting; named dialling must therefore use the host resolver path.
do
  local host = SimulatedHost.new({
    sockets = true,
    datagrams = true,
    resolver_records = {
      ['dns-disabled.test'] = { { kind = 'inet4', host = '127.0.0.1' } },
    },
  })
  local resolve_calls = 0
  local base_resolve = host.resolve
  host.resolve = function(self, endpoint, options)
    resolve_calls = resolve_calls + 1
    return base_resolve(self, endpoint, options)
  end

  fibers.run(function()
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local address = listener:local_address()
    host.resolver_records['dns-disabled.test'][1].port = address.port

    local dial = socket.dial(socket.name_endpoint('dns-disabled.test', address.port), {
      dns = false,
      resolver_options = { dns = true },
      destination_ordering = 'stable',
    })
    local client = assert(dial:result())
    local server = assert(listener:accept())
    assert_eq(resolve_calls, 1, 'top-level dns=false must select host resolution')
    client:close('dns override test complete')
    server:close('dns override test complete')
    listener:close('dns override test complete')
  end, { host = host })
end

print('tests/io/test_happy_eyeballs.lua: ok')
