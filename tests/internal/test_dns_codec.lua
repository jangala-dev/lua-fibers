package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/?.lua',
  package.path,
}, ';')

local Codec = require('fibers.dns.codec')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local query = Codec.encode_query(0x1234, 'Example.TEST.', 'AAAA', {
  udp_payload_size = 1232,
})
local decoded_query = assert(Codec.decode_message(query))
assert_eq(decoded_query.id, 0x1234)
assert_eq(decoded_query.qr, false)
assert_eq(decoded_query.questions[1].name, 'example.test')
assert_eq(decoded_query.questions[1].type, Codec.TYPE_AAAA)
assert_eq(decoded_query.additional[1].type, Codec.TYPE_OPT)
assert_eq(decoded_query.additional[1].udp_payload_size, 1232)

local response = Codec.encode_response({
  id = decoded_query.id,
  questions = decoded_query.questions,
  answers = {
    { name = 'example.test', type = 'CNAME', target = 'edge.example.test', ttl = 120 },
    { name = 'edge.example.test', type = 'A', address = '192.0.2.4', ttl = 60 },
    { name = 'edge.example.test', type = 'AAAA', address = '2001:db8::4', ttl = 60 },
  },
  authority = {
    {
      name = 'example.test',
      type = 'SOA',
      ttl = 300,
      soa = {
        mname = 'ns.example.test',
        rname = 'hostmaster.example.test',
        serial = 7,
        refresh = 3600,
        retry = 600,
        expire = 86400,
        minimum = 30,
      },
    },
  },
})
local message = assert(Codec.decode_message(response))
assert_eq(message.qr, true)
assert_eq(message.answers[1].target, 'edge.example.test')
assert_eq(message.answers[2].address, '192.0.2.4')
assert_eq(message.answers[3].address, '2001:db8::4')
assert_eq(message.authority[1].soa.minimum, 30)
assert_eq(message.trailing_bytes, 0)

local framed = Codec.frame_tcp(response)
assert_eq(Codec.read_u16(framed), #response)
assert_eq(string.sub(framed, 3), response)

local ok = pcall(Codec.encode_name, string.rep('x', 64) .. '.test')
assert_eq(ok, false, 'overlong labels must be rejected')

-- A forward compression pointer is invalid and must not be followed.
local bad_pointer = string.char(
  0,
  1, -- id
  1,
  0, -- flags
  0,
  1, -- qdcount
  0,
  0,
  0,
  0,
  0,
  0,
  192,
  14, -- pointer from wire offset 12 to wire offset 14
  0,
  1,
  0,
  1
)
local bad, pointer_err = Codec.decode_message(bad_pointer)
assert_eq(bad, nil)
assert(string.find(pointer_err, 'refer backwards', 1, true), pointer_err)

local truncated = string.sub(response, 1, #response - 1)
local incomplete, truncated_err = Codec.decode_message(truncated)
assert_eq(incomplete, nil)
assert(type(truncated_err) == 'string' and truncated_err ~= '')

-- IPv6 rendering must produce canonical valid compression at every boundary.
for _, address in ipairs({ '::', '::1', '2001:db8::', '2001:db8::1', '2001:db8:0:1:0:0:0:0', 'fe80::' }) do
  local wire = Codec.encode_response({
    id = 1,
    questions = { { name = 'ipv6.test', type = 'AAAA' } },
    answers = { { name = 'ipv6.test', type = 'AAAA', address = address } },
  })
  local decoded = assert(Codec.decode_message(wire))
  assert(not string.find(decoded.answers[1].address, ':::', 1, true), decoded.answers[1].address)
end

-- EDNS extended response codes are combined with the header response code.
local badvers = Codec.encode_response({
  id = 9,
  rcode = 0,
  questions = { { name = 'edns.test', type = 'A' } },
  additional = { { name = '.', type = 'OPT', class = 1232, ttl = 16777216, raw = '' } },
})
local badvers_message = assert(Codec.decode_message(badvers))
assert_eq(badvers_message.rcode, 16)

print('tests/internal/test_dns_codec.lua: ok')
