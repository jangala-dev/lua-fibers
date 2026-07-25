package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/?.lua',
  package.path,
}, ';')

local Resolver = require('fibers.dns.resolver')
local Codec = require('fibers.dns.codec')
local Address = require('fibers.socket.address')
local Policy = require('fibers.internal.socket.happy_eyeballs_policy')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function nx_message(with_soa)
  local authority = {}
  if with_soa then
    authority[1] = {
      name = 'test',
      type = Codec.TYPE_SOA,
      ttl = 60,
      soa = { minimum = 30 },
    }
  end
  return { rcode = Codec.RCODE.NXDOMAIN, authority = authority, answers = {} }
end

-- A negative answer without an SOA has no authoritative cache lifetime.
do
  local resolver = Resolver.new({ maximum_cache_entries = 8, read_hosts = false })
  local exchanges = 0
  function resolver:_exchange()
    exchanges = exchanges + 1
    return nx_message(false)
  end
  assert_eq(resolver:resolve_type('missing.test', Codec.TYPE_A), nil)
  assert_eq(resolver:resolve_type('missing.test', Codec.TYPE_A), nil)
  assert_eq(exchanges, 2)
end

-- NXDOMAIN with an SOA is cached for the whole QNAME, not just one QTYPE.
do
  local resolver = Resolver.new({ maximum_cache_entries = 8, read_hosts = false })
  local exchanges = 0
  function resolver:_exchange()
    exchanges = exchanges + 1
    return nx_message(true)
  end
  assert_eq(resolver:resolve_type('absent.test', Codec.TYPE_A), nil)
  assert_eq(resolver:resolve_type('absent.test', Codec.TYPE_AAAA), nil)
  assert_eq(exchanges, 1)
end

-- CNAME limits count every alias, including aliases contained in one answer.
do
  local resolver = Resolver.new({ maximum_cache_entries = 0, read_hosts = false })
  function resolver:_exchange()
    return {
      rcode = Codec.RCODE.NOERROR,
      authority = {},
      answers = {
        { name = 'a.test', type = Codec.TYPE_CNAME, class = Codec.CLASS_IN, target = 'b.test', ttl = 60 },
        { name = 'b.test', type = Codec.TYPE_CNAME, class = Codec.CLASS_IN, target = 'c.test', ttl = 60 },
        { name = 'c.test', type = Codec.TYPE_A, class = Codec.CLASS_IN, address = '192.0.2.1', ttl = 60 },
      },
    }
  end
  local values, err = resolver:resolve_type('a.test', Codec.TYPE_A, { maximum_cnames = 1 })
  assert_eq(values, nil)
  assert(string.find(tostring(err), 'exceeds configured limit', 1, true), tostring(err))
end

-- A mismatched truncated response cannot request TCP fallback.
do
  local server = Address.ipv4('192.0.2.53', 53)
  local wire = Codec.encode_response({
    id = 99,
    truncated = true,
    questions = { { name = 'example.test', type = 'A' } },
  })
  local decision = Resolver.classify_udp_packet(
    { peer = server, data = wire },
    server,
    100,
    'example.test',
    Codec.TYPE_A,
    {}
  )
  assert_eq(decision.kind, 'invalid')
end

-- Keep one slot available for the other unfinished address family.
do
  local race = {
    endpoint = Address.name('example.test', 443),
    maximum_candidates = 2,
    first_family_count = 1,
    opts = {},
  }
  local current = {
    families = {
      inet6 = { done = false, addresses = {} },
      inet4 = { done = false, addresses = {} },
    },
    unattempted = {},
    seen = {},
    attempts = {},
  }
  local ordered, added, err, dropped = Policy.order_candidates(race, current, 'inet6', {
    Address.ipv6('2001:db8::1', 443),
    Address.ipv6('2001:db8::2', 443),
  })
  assert(err == nil, tostring(err))
  assert_eq(#ordered, 1)
  assert_eq(#added, 1)
  assert_eq(dropped, 1)
end

print('tests/internal/test_dns_hardening.lua: ok')
