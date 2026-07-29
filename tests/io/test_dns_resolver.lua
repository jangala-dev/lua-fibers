package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Sleep = require('fibers.sleep')
local socket = require('fibers.socket')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.io.error')
local Codec = require('fibers.dns.codec')

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

local function deterministic_ids(start)
  local value = start or 0
  return function()
    value = (value + 1) % 65536
    return value
  end
end

-- A and AAAA are issued concurrently over Fibers datagrams.  The second
-- resolution is served from the resolver's positive cache.
do
  local host = SimulatedHost.new({ sockets = true, datagrams = true, resolver = false })
  local report = fibers.try_run(function(scope)
    local server = assert(socket.udp_ipv4('127.0.0.1', 0))
    local name_server = server:local_address()
    local questions = 0

    local service = scope:spawn(function()
      for _ = 1, 2 do
        local packet = assert(server:receive_from())
        local request = assert(Codec.decode_message(packet.data))
        local question = request.questions[1]
        questions = questions + 1
        local answer = question.type == Codec.TYPE_AAAA
            and { name = question.name, type = 'AAAA', address = '2001:db8::25', ttl = 60 }
          or { name = question.name, type = 'A', address = '192.0.2.25', ttl = 60 }
        assert(server:send_to(
          Codec.encode_response({
            id = request.id,
            questions = request.questions,
            answers = { answer },
          }),
          packet.peer
        ))
        assert(server:flush())
      end
      server:close('DNS fixture complete')
    end, 'dns-address-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { name_server },
      attempts = 1,
      timeout = 0.1,
      random_u16 = deterministic_ids(100),
      read_hosts = false,
    })

    for _ = 1, 2 do
      local query = socket.resolve_name('service.test', 8443, { resolver = resolver })
      local addresses, err = query:result()
      assert_truthy(addresses, tostring(err))
      assert_eq(#addresses, 2)
      assert_eq(addresses[1].kind, 'inet6')
      assert_eq(addresses[1].host, '2001:db8::25')
      assert_eq(addresses[2].kind, 'inet4')
      assert_eq(addresses[2].host, '192.0.2.25')
      assert_eq(addresses[2].port, 8443)
      query:close('result collected')
    end
    assert_eq(questions, 2, 'cached resolution should not issue another packet')
    service:await()
  end, { host = host })
  assert_truthy(report.ok, report:tostring())
  report.runtime:assert_io_quiescent('DNS UDP and cache')
end

-- Family completion is published independently, providing the dynamic source
-- closure needed by a Happy Eyeballs coordinator.
do
  local host = SimulatedHost.new({ sockets = true, datagrams = true, resolver = false })
  fibers.run(function(scope)
    local server = assert(socket.udp_ipv4('127.0.0.1', 0))
    local name_server = server:local_address()
    local service = scope:spawn(function()
      local pending_a
      for _ = 1, 2 do
        local packet = assert(server:receive_from())
        local request = assert(Codec.decode_message(packet.data))
        local question = request.questions[1]
        if question.type == Codec.TYPE_AAAA then
          assert(server:send_to(
            Codec.encode_response({
              id = request.id,
              questions = request.questions,
              answers = {
                { name = question.name, type = 'AAAA', address = '2001:db8::88', ttl = 60 },
              },
            }),
            packet.peer
          ))
          assert(server:flush())
        else
          pending_a = { packet = packet, request = request }
        end
      end
      Sleep.sleep(0.05)
      local question = pending_a.request.questions[1]
      assert(server:send_to(
        Codec.encode_response({
          id = pending_a.request.id,
          questions = pending_a.request.questions,
          answers = {
            { name = question.name, type = 'A', address = '192.0.2.88', ttl = 60 },
          },
        }),
        pending_a.packet.peer
      ))
      assert(server:flush())
      server:close('family fixture complete')
    end, 'dns-family-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { name_server },
      attempts = 1,
      timeout = 0.2,
      random_u16 = deterministic_ids(150),
      read_hosts = false,
    })
    local query = socket.resolve_name('families.test', 443, { resolver = resolver })
    local ipv6 = assert(query:family_addresses('inet6'))
    assert_eq(ipv6[1].host, '2001:db8::88')
    assert_eq(host:now(), 0, 'IPv6 should be available before the delayed IPv4 result')
    local addresses = assert(query:result())
    assert_eq(addresses[1].kind, 'inet6')
    assert_eq(addresses[2].kind, 'inet4')
    assert_truthy(host:now() >= 0.05)
    query:close('family result collected')
    service:await()
  end, { host = host })
end

-- CNAME chains can be completed from one coherent answer.
do
  local host = SimulatedHost.new({ sockets = true, datagrams = true, resolver = false })
  fibers.run(function(scope)
    local server = assert(socket.udp_ipv4('127.0.0.1', 0))
    local name_server = server:local_address()
    local service = scope:spawn(function()
      local packet = assert(server:receive_from())
      local request = assert(Codec.decode_message(packet.data))
      local question = request.questions[1]
      assert(server:send_to(
        Codec.encode_response({
          id = request.id,
          questions = request.questions,
          answers = {
            { name = question.name, type = 'CNAME', target = 'edge.test', ttl = 120 },
            { name = 'edge.test', type = 'A', address = '198.51.100.8', ttl = 30 },
          },
        }),
        packet.peer
      ))
      assert(server:flush())
      server:close('CNAME fixture complete')
    end, 'dns-cname-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { name_server },
      attempts = 1,
      timeout = 0.1,
      random_u16 = deterministic_ids(200),
      read_hosts = false,
    })
    local query = socket.resolve_name('alias.test', 80, { resolver = resolver, family = 'inet4' })
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(addresses[1].host, '198.51.100.8')
    query:close('CNAME result collected')
    service:await()
  end, { host = host })
end

-- A truncated UDP reply is retried over a Fibers TCP stream using the same
-- transaction id and question.
do
  local host = SimulatedHost.new({ sockets = true, datagrams = true, resolver = false })
  local report = fibers.try_run(function(scope)
    local port = 5533
    local udp = assert(socket.udp_ipv4('127.0.0.1', port))
    local listener = assert(socket.listen_ipv4('127.0.0.1', port))
    local name_server = udp:local_address()

    local udp_service = scope:spawn(function()
      local packet = assert(udp:receive_from())
      local request = assert(Codec.decode_message(packet.data))
      assert(udp:send_to(
        Codec.encode_response({
          id = request.id,
          questions = request.questions,
          truncated = true,
        }),
        packet.peer
      ))
      assert(udp:flush())
      udp:close('UDP fallback fixture complete')
    end, 'dns-truncated-udp')

    local tcp_service = scope:spawn(function()
      local connection = assert(listener:accept())
      local prefix = assert(connection:read_exactly(2))
      local length = assert(Codec.read_u16(prefix))
      local request = assert(Codec.decode_message(assert(connection:read_exactly(length))))
      local question = request.questions[1]
      local response = Codec.encode_response({
        id = request.id,
        questions = request.questions,
        answers = {
          { name = question.name, type = 'A', address = '203.0.113.9', ttl = 45 },
        },
      })
      assert(connection:write(Codec.frame_tcp(response)))
      assert(connection:flush())
      connection:close('TCP fallback fixture complete')
      listener:close('TCP fallback fixture complete')
    end, 'dns-tcp-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { name_server },
      attempts = 1,
      timeout = 0.1,
      tcp_timeout = 0.2,
      random_u16 = deterministic_ids(300),
      read_hosts = false,
    })
    local query = socket.resolve_name('fallback.test', 443, { resolver = resolver, family = 'inet4' })
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(addresses[1].host, '203.0.113.9')
    query:close('TCP result collected')
    udp_service:await()
    tcp_service:await()
  end, { host = host })
  assert_truthy(report.ok, report:tostring())
  report.runtime:assert_io_quiescent('DNS TCP fallback')
end

-- Timeouts advance to the next configured server rather than repeatedly using
-- the first server before alternatives have been tried.
do
  local host = SimulatedHost.new({ sockets = true, datagrams = true, resolver = false })
  fibers.run(function(scope)
    local working = assert(socket.udp_ipv4('127.0.0.1', 0))
    local dead = socket.ipv4_address('127.0.0.1', working:local_address().port + 1)
    local service = scope:spawn(function()
      local packet = assert(working:receive_from())
      local request = assert(Codec.decode_message(packet.data))
      local question = request.questions[1]
      assert(working:send_to(
        Codec.encode_response({
          id = request.id,
          questions = request.questions,
          answers = {
            { name = question.name, type = 'A', address = '192.0.2.77', ttl = 10 },
          },
        }),
        packet.peer
      ))
      assert(working:flush())
      working:close('retry fixture complete')
    end, 'dns-second-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { dead, working:local_address() },
      attempts = 1,
      timeout = 0.05,
      random_u16 = deterministic_ids(400),
      read_hosts = false,
    })
    local query = socket.resolve_name('retry.test', 53, { resolver = resolver, family = 'inet4' })
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(addresses[1].host, '192.0.2.77')
    assert_truthy(host:now() >= 0.05, 'first-server timeout should advance manual time')
    query:close('retry result collected')
    service:await()
  end, { host = host })
end

-- NXDOMAIN is a terminal, structured result rather than an exception.
do
  local host = SimulatedHost.new({ sockets = true, datagrams = true, resolver = false })
  fibers.run(function(scope)
    local server = assert(socket.udp_ipv4('127.0.0.1', 0))
    local service = scope:spawn(function()
      local packet = assert(server:receive_from())
      local request = assert(Codec.decode_message(packet.data))
      assert(server:send_to(
        Codec.encode_response({
          id = request.id,
          questions = request.questions,
          rcode = Codec.RCODE.NXDOMAIN,
          authority = {
            {
              name = 'test',
              type = 'SOA',
              ttl = 60,
              soa = {
                mname = 'ns.test',
                rname = 'hostmaster.test',
                serial = 1,
                refresh = 60,
                retry = 60,
                expire = 60,
                minimum = 15,
              },
            },
          },
        }),
        packet.peer
      ))
      assert(server:flush())
      server:close('NXDOMAIN fixture complete')
    end, 'dns-nxdomain-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { server:local_address() },
      attempts = 1,
      timeout = 0.1,
      random_u16 = deterministic_ids(500),
      read_hosts = false,
    })
    local query = socket.resolve_name('missing.test', 80, { resolver = resolver, family = 'inet4' })
    local addresses, err = query:result()
    assert_eq(addresses, nil)
    assert_truthy(HostError.is(err, 'system'))
    assert_eq(err.code, 'EAI_NONAME')
    query:close('NXDOMAIN collected')

    local cached = socket.resolve_name('missing.test', 80, {
      resolver = resolver,
      family = 'inet4',
    })
    local cached_addresses, cached_err = cached:result()
    assert_eq(cached_addresses, nil)
    assert_truthy(HostError.is(cached_err, 'system'))
    assert_eq(cached_err.code, 'EAI_NONAME')
    assert_truthy(cached_err ~= err, 'negative cache must return a fresh error value')
    cached:close('cached NXDOMAIN collected')
    service:await()
  end, { host = host })
end

-- Resolver configuration, hosts data and entropy use the evented fibers.file
-- provider rather than synchronous Lua file handles.
do
  local host = SimulatedHost.new({
    sockets = true,
    datagrams = true,
    resolver = false,
    files = {
      ['/etc/resolv.conf'] = table.concat({
        'nameserver 192.0.2.53',
        'search example.test',
        'options timeout:3 attempts:4 ndots:2',
        '',
      }, '\n'),
      ['/etc/hosts'] = '192.0.2.44 local-file.test local-file-alias.test\n',
    },
  })
  local report = fibers.try_run(function()
    local resolver = socket.dns_resolver({ host = host })
    local config, config_err = resolver:configuration()
    assert_truthy(config, tostring(config_err))
    assert_eq(config.nameservers[1].host, '192.0.2.53')
    assert_eq(config.search[1], 'example.test')
    assert_eq(config.timeout, 3)
    assert_eq(config.attempts, 4)
    assert_eq(config.ndots, 2)

    local query = socket.resolve_name('local-file.test', 8443, { resolver = resolver })
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(#addresses, 1)
    assert_eq(addresses[1].kind, 'inet4')
    assert_eq(addresses[1].host, '192.0.2.44')
    assert_eq(addresses[1].port, 8443)
    assert_eq(resolver:has_static_name('local-file-alias.test'), true)
    query:close('file-backed hosts result collected')
  end, { host = host })
  assert_truthy(report.ok, report:tostring())
  report.runtime:assert_io_quiescent('DNS fibers.file configuration')
end

-- Secure transaction identifiers may be supplied by the non-blocking file
-- provider. Secure entropy is required by default.
do
  local host = SimulatedHost.new({
    sockets = true,
    datagrams = true,
    resolver = false,
    files = { ['/dev/urandom'] = string.char(0x12, 0x34) },
  })
  local report = fibers.try_run(function(scope)
    local server = assert(socket.udp_ipv4('127.0.0.1', 0))
    local service = scope:spawn(function()
      local packet = assert(server:receive_from())
      local request = assert(Codec.decode_message(packet.data))
      assert_eq(request.id, 0x1234)
      local question = request.questions[1]
      assert(server:send_to(
        Codec.encode_response({
          id = request.id,
          questions = request.questions,
          answers = {
            { name = question.name, type = 'A', address = '192.0.2.18', ttl = 30 },
          },
        }),
        packet.peer
      ))
      assert(server:flush())
      server:close('entropy fixture complete')
    end, 'dns-file-entropy-server')

    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { server:local_address() },
      attempts = 1,
      timeout = 0.1,
      read_hosts = false,
    })
    local query = socket.resolve_name('entropy.test', 53, { resolver = resolver, family = 'inet4' })
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(addresses[1].host, '192.0.2.18')
    assert_eq(resolver.secure_ids, true)
    query:close('entropy result collected')
    service:await()
  end, { host = host })
  assert_truthy(report.ok, report:tostring())
  report.runtime:assert_io_quiescent('DNS fibers.file entropy')
end

-- Secure entropy is the default policy. Missing entropy fails before any DNS
-- packet is sent unless the caller explicitly permits the weak fallback.
do
  local host = SimulatedHost.new({
    sockets = true,
    datagrams = true,
    resolver = false,
    files = {},
  })
  local report = fibers.try_run(function()
    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { socket.ipv4_address('192.0.2.53', 53) },
      attempts = 1,
      timeout = 0.1,
      read_hosts = false,
    })
    local addresses, err = resolver:resolve_type('strict-entropy.test', Codec.TYPE_A, {})
    assert_eq(addresses, nil)
    assert_truthy(HostError.is(err, 'unsupported'))
    assert_eq(err.code, 'dns_secure_random_unavailable')
    assert_eq(resolver.secure_ids, false)
  end, { host = host })
  assert_truthy(report.ok, report:tostring())
  report.runtime:assert_io_quiescent('DNS strict entropy default')
end

-- The resolver cache has a deterministic FIFO bound. Re-reading the oldest
-- name after inserting a third entry performs another exchange.
do
  local host = SimulatedHost.new({ resolver = false })
  local report = fibers.try_run(function()
    local resolver = socket.dns_resolver({
      host = host,
      nameservers = { socket.ipv4_address('192.0.2.53', 53) },
      maximum_cache_entries = 2,
      read_hosts = false,
      random_u16 = deterministic_ids(900),
    })
    local exchanges = 0
    resolver._exchange = function(_self, name, qtype)
      exchanges = exchanges + 1
      return {
        rcode = Codec.RCODE.NOERROR,
        answers = {
          {
            name = name,
            type = qtype,
            class = Codec.CLASS_IN,
            address = '192.0.2.' .. tostring(10 + exchanges),
            ttl = 60,
          },
        },
        authority = {},
      }
    end

    for _, name in ipairs({ 'one.test', 'two.test', 'three.test', 'one.test' }) do
      local values, err = resolver:resolve_type(name, Codec.TYPE_A, {})
      assert_truthy(values, tostring(err))
    end
    assert_eq(exchanges, 4, 'the oldest cache entry should have been evicted')
    assert_eq(#resolver.cache_order, 2)
  end, { host = host })
  assert_truthy(report.ok, report:tostring())
end

print('tests/io/test_dns_resolver.lua: ok')
