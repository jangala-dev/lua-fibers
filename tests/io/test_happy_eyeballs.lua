package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Sleep = require('fibers.sleep')
local Op = require('fibers.op')
local socket = require('fibers.socket')
local Host = require('fibers.host')
local HostError = require('fibers.host.error')

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
  local host = Host.manual({ sockets = true, resolver_records = {} })
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
    end, 'happy-eyeballs-v6-server')

    local connection, report = socket.connect_name('dual.test', actual.port)
    assert_truthy(connection, tostring(report))
    assert_eq(report.status, 'connected')
    assert_eq(report.winner.family, 'inet6')
    assert_eq(#report.attempts, 1)
    assert_eq(report.attempts[1].address.port, actual.port)
    connection:close('Happy Eyeballs client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  result.runtime:assert_io_quiescent('Happy Eyeballs IPv6 winner')
end

-- A global destination policy may prefer IPv4.  Both DNS family completions
-- are consumed before admission, so the first family comes from the combined
-- ordering rather than a hard-coded IPv6 preference.
do
  local host = Host.manual({ sockets = true, resolver_records = {} })
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
    end, 'happy-eyeballs-v4-first-server')

    local connection, report = socket.connect_name('ipv4-first.test', port, {
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
  result.runtime:assert_io_quiescent('Happy Eyeballs global destination ordering')
end

-- An immediate failure accelerates the next family rather than waiting for the
-- connection-attempt delay.
do
  local host = Host.manual({ sockets = true, resolver_records = {} })
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
    end, 'happy-eyeballs-v4-server')

    local connection, report = socket.connect_name('fallback.test', actual.port, {
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
  result.runtime:assert_io_quiescent('Happy Eyeballs accelerated fallback')
end

local function dynamic_resolution_case(aaaa_delay, resolution_delay, expected_family)
  local host = Host.manual({ sockets = true, resolver = false })
  local result = fibers.try_run(function(scope)
    local listener4 = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener4:local_address().port
    local listener6 = assert(socket.listen_ipv6('::1', port))

    local expected_listener = expected_family == 'inet4' and listener4 or listener6
    local server = scope:spawn(function()
      local connection = assert(expected_listener:accept())
      connection:close('dynamic Happy Eyeballs fixture complete')
    end, 'happy-eyeballs-expected-server')

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
    local connection, report = socket.connect_name('dynamic.test', port, {
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
  result.runtime:assert_io_quiescent('dynamic Happy Eyeballs')
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
      local handle = { _connect_pending = true, _connect_complete = false }
      function handle:bind_runtime(runtime)
        self.runtime = runtime
      end
      function handle:write_ready_op()
        return Sleep.sleep_op(100)
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

  local host = Host.manual({ sockets = true, resolver = false, dial_factory = dial_factory })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener:local_address().port
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end, 'happy-eyeballs-stagger-server')
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

    local connection, report = socket.connect_name('stagger.test', port, {
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
    assert_eq(pending_closed, true, 'the losing pending socket is settled before connect_name returns')
    connection:close('stagger client complete')
    server:await()
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  result.runtime:assert_io_quiescent('Happy Eyeballs staggered attempt')
end

-- first_family_count permits a bounded run from the initially preferred
-- family before ordinary alternation resumes.
do
  local host = Host.manual({
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
    end, 'happy-eyeballs-first-family-server')

    local connection, report = socket.connect_name('first-family.test', port, {
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
  result.runtime:assert_io_quiescent('Happy Eyeballs first-family count')
end

-- Destination ordering can be injected without placing socket work in a
-- speculative callback.
do
  local host = Host.manual({
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
    end, 'happy-eyeballs-sorted-server')

    local connection, report = socket.connect_name('sorted.test', port, {
      sort_addresses = function(addresses, family)
        assert_eq(family, 'inet6')
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
  result.runtime:assert_io_quiescent('Happy Eyeballs destination ordering')
end

-- A relative timeout starts when the admitted driver begins, not when an inert
-- dial option is constructed.
do
  local host = Host.manual({ sockets = true, resolver = false })
  local result = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0))
    local port = listener:local_address().port
    local server = scope:spawn(function()
      local connection = assert(listener:accept())
      close_server(listener, connection)
    end, 'happy-eyeballs-inert-timeout-server')
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

    local dial_op = socket.dial_name_op('inert.test', port, {
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
  result.runtime:assert_io_quiescent('Happy Eyeballs inert timeout')
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
    function handle:write_ready_op()
      return Sleep.sleep_op(0.250)
    end
    function handle:finish_connect()
      self._connect_pending = false
      self._connect_complete = true
      return self, address
    end
    return handle
  end

  local host = Host.manual({ sockets = true, resolver_records = {}, dial_factory = dial_factory })
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
    end, 'happy-eyeballs-boundary-server')

    local connection, report = socket.connect_name('boundary.test', port, {
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
  result.runtime:assert_io_quiescent('Happy Eyeballs timer boundary')
end

-- Certified exhaustion reports every failed attempt.
do
  local host = Host.manual({
    sockets = true,
    resolver_records = {
      ['dead.test'] = {
        { kind = 'inet6', host = '::1' },
        { kind = 'inet4', host = '127.0.0.1' },
      },
    },
  })
  fibers.run(function()
    local connection, err = socket.connect_name('dead.test', 6553, { attempt_delay = 1.0 })
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
  local host = Host.manual({
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
    local value = fibers.perform(Op.always('winner'):or_else(socket.dial_name_op('unused.test', 80)))
    assert_eq(value, 'winner')
  end, { host = host })
  assert_eq(resolve_calls, 0)
  assert_eq(dial_calls, 0)
end

-- Destination policy receives the resolver's stable order, not an address-key
-- canonicalisation. The callback may use that order as its final tie-break.
do
  local host = Host.manual({
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
    end, 'happy-eyeballs-stable-order-server')

    local connection, report = socket.connect_name('stable-order.test', port, {
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
  result.runtime:assert_io_quiescent('Happy Eyeballs stable ordering input')
end

-- RFC 8305's absolute 10 millisecond attempt-delay floor is validated before
-- any named Dial is admitted.
do
  local host = Host.manual({ sockets = true, resolver_records = {} })
  fibers.run(function()
    local ok, err = pcall(socket.dial_name_op, 'invalid-delay.test', 80, {
      attempt_delay = 0.009,
    })
    assert_eq(ok, false)
    assert_truthy(string.find(tostring(err), 'at least 0.010 seconds', 1, true))
  end, { host = host })
end

-- The retained candidate set is bounded and reports discarded destinations.
do
  local host = Host.manual({
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
    local connection, err = socket.connect_name('candidate-bound.test', 6553, {
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

-- Pending attempts are bounded. The default-connect-timeout option supplies the
-- deadline, and timeout diagnostics contain summaries rather than live Dials.
do
  local dial_calls, closed = 0, 0
  local function pending_dial(_host, address)
    dial_calls = dial_calls + 1
    local handle = { _connect_pending = true, _connect_complete = false }
    function handle:bind_runtime(runtime)
      self.runtime = runtime
    end
    function handle:write_ready_op()
      return Sleep.sleep_op(100)
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

  local host = Host.manual({
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
    local connection, err = socket.connect_name('active-bound.test', 443, {
      attempt_delay = 0.010,
      maximum_active_attempts = 2,
      default_connect_timeout = 0.030,
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
    assert_eq(closed, 2, 'bounded pending Dials should settle before return')
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
  result.runtime:assert_io_quiescent('Happy Eyeballs active attempt bound')
end

print('tests/io/test_happy_eyeballs.lua: ok')
