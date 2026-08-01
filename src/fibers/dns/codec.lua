-- Pure DNS wire codec.
--
-- The decoder treats input as hostile: every offset and count is bounded,
-- compression pointers are cycle checked, and expanded names are limited to
-- the DNS wire maximum.  The module intentionally depends on no host or Fibers
-- runtime facilities so it can be fuzzed and tested independently.

local Codec = {}

Codec.CLASS_IN = 1
Codec.TYPE_A = 1
Codec.TYPE_CNAME = 5
Codec.TYPE_SOA = 6
Codec.TYPE_AAAA = 28
Codec.TYPE_OPT = 41

Codec.RCODE = {
  NOERROR = 0,
  FORMERR = 1,
  SERVFAIL = 2,
  NXDOMAIN = 3,
  NOTIMP = 4,
  REFUSED = 5,
}

local TYPE_BY_NAME = {
  A = Codec.TYPE_A,
  CNAME = Codec.TYPE_CNAME,
  SOA = Codec.TYPE_SOA,
  AAAA = Codec.TYPE_AAAA,
  OPT = Codec.TYPE_OPT,
}
local NAME_BY_TYPE = {}
for name, value in pairs(TYPE_BY_NAME) do
  NAME_BY_TYPE[value] = name
end

local function u16(data, offset)
  local a, b = string.byte(data, offset, offset + 1)
  if not b then
    return nil, 'truncated 16-bit integer'
  end
  return a * 256 + b
end

local function u32(data, offset)
  local a, b, c, d = string.byte(data, offset, offset + 3)
  if not d then
    return nil, 'truncated 32-bit integer'
  end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function put_u16(value)
  value = math.floor(tonumber(value) or 0) % 65536
  return string.char(math.floor(value / 256), value % 256)
end

local function put_u32(value)
  value = math.floor(tonumber(value) or 0) % 4294967296
  local a = math.floor(value / 16777216) % 256
  local b = math.floor(value / 65536) % 256
  local c = math.floor(value / 256) % 256
  local d = value % 256
  return string.char(a, b, c, d)
end

local function normalise_type(value)
  if type(value) == 'string' then
    value = TYPE_BY_NAME[string.upper(value)]
  end
  value = tonumber(value)
  if not value or value < 0 or value > 65535 or value ~= math.floor(value) then
    error('DNS record type must be a name or 16-bit integer', 3)
  end
  return value
end

function Codec.type_code(value)
  return normalise_type(value)
end

function Codec.type_name(value)
  return NAME_BY_TYPE[tonumber(value)] or tostring(value)
end

function Codec.normalise_name(name)
  if type(name) ~= 'string' or name == '' then
    error('DNS name must be a non-empty string', 2)
  end
  if name == '.' then
    return ''
  end
  if string.sub(name, -1) == '.' then
    name = string.sub(name, 1, -2)
  end
  if name == '' then
    return ''
  end
  local labels, wire_length, cursor = {}, 1, 1
  while cursor <= #name do
    local dot = string.find(name, '.', cursor, true)
    local label = dot and string.sub(name, cursor, dot - 1) or string.sub(name, cursor)
    if label == '' then
      error('DNS name contains an empty label', 2)
    end
    if #label > 63 then
      error('DNS label exceeds 63 octets', 2)
    end
    wire_length = wire_length + 1 + #label
    if wire_length > 255 then
      error('DNS name exceeds 255 wire octets', 2)
    end
    labels[#labels + 1] = string.lower(label)
    if not dot then
      break
    end
    cursor = dot + 1
  end
  return table.concat(labels, '.')
end

function Codec.encode_name(name)
  name = Codec.normalise_name(name)
  if name == '' then
    return '\0'
  end
  local out = {}
  for label in string.gmatch(name, '[^.]+') do
    out[#out + 1] = string.char(#label)
    out[#out + 1] = label
  end
  out[#out + 1] = '\0'
  return table.concat(out)
end

function Codec.decode_name(data, offset, opts)
  opts = opts or {}
  offset = tonumber(offset) or 1
  if offset < 1 or offset > #data then
    return nil, nil, 'DNS name offset is outside the message'
  end

  local labels, visited = {}, {}
  local pos, next_offset, depth, expanded = offset, nil, 0, 1
  local max_depth = tonumber(opts.max_pointer_depth or 32)

  while true do
    if visited[pos] then
      return nil, nil, 'DNS compression pointer cycle'
    end
    visited[pos] = true

    local length = string.byte(data, pos)
    if length == nil then
      return nil, nil, 'truncated DNS name'
    end

    if length >= 192 then
      local second = string.byte(data, pos + 1)
      if second == nil then
        return nil, nil, 'truncated DNS compression pointer'
      end
      local pointer = (length - 192) * 256 + second + 1
      if pointer >= pos then
        return nil, nil, 'DNS compression pointer must refer backwards'
      end
      if pointer < 1 or pointer > #data then
        return nil, nil, 'DNS compression pointer is outside the message'
      end
      if not next_offset then
        next_offset = pos + 2
      end
      depth = depth + 1
      if depth > max_depth then
        return nil, nil, 'DNS compression pointer depth exceeded'
      end
      pos = pointer
    elseif length >= 64 then
      return nil, nil, 'reserved DNS label encoding'
    elseif length == 0 then
      next_offset = next_offset or (pos + 1)
      return table.concat(labels, '.'), next_offset
    else
      local last = pos + length
      if last > #data then
        return nil, nil, 'truncated DNS label'
      end
      local label = string.sub(data, pos + 1, last)
      expanded = expanded + length + 1
      if expanded > 255 then
        return nil, nil, 'expanded DNS name exceeds 255 octets'
      end
      labels[#labels + 1] = label
      pos = last + 1
    end
  end
end

local function ipv4_to_bytes(address)
  local parts = {}
  for part in string.gmatch(address or '', '[^.]+') do
    local value = tonumber(part)
    if not value or value < 0 or value > 255 or value ~= math.floor(value) then
      error('invalid IPv4 address ' .. tostring(address), 3)
    end
    parts[#parts + 1] = value
  end
  if #parts ~= 4 then
    error('invalid IPv4 address ' .. tostring(address), 3)
  end
  return string.char(parts[1], parts[2], parts[3], parts[4])
end

local function split_ipv6_side(side)
  local out = {}
  if side == nil or side == '' then
    return out
  end
  for item in string.gmatch(side, '[^:]+') do
    local value = tonumber(item, 16)
    if not value or value < 0 or value > 65535 then
      error('invalid IPv6 group ' .. tostring(item), 4)
    end
    out[#out + 1] = value
  end
  return out
end

local function parse_ipv6(address)
  address = tostring(address or '')
  local percent = string.find(address, '%%')
  if percent then
    address = string.sub(address, 1, percent - 1)
  end
  local marker = string.find(address, '::', 1, true)
  local left, right
  if marker then
    if string.find(address, '::', marker + 2, true) then
      error('invalid IPv6 address ' .. tostring(address), 3)
    end
    left = split_ipv6_side(string.sub(address, 1, marker - 1))
    right = split_ipv6_side(string.sub(address, marker + 2))
    local missing = 8 - #left - #right
    if missing < 1 then
      error('invalid compressed IPv6 address ' .. tostring(address), 3)
    end
    local groups = {}
    for i = 1, #left do
      groups[#groups + 1] = left[i]
    end
    for _ = 1, missing do
      groups[#groups + 1] = 0
    end
    for i = 1, #right do
      groups[#groups + 1] = right[i]
    end
    return groups
  end
  local groups = split_ipv6_side(address)
  if #groups ~= 8 then
    error('invalid IPv6 address ' .. tostring(address), 3)
  end
  return groups
end

local function ipv6_to_bytes(address)
  local groups = parse_ipv6(address)
  local out = {}
  for i = 1, 8 do
    out[#out + 1] = put_u16(groups[i])
  end
  return table.concat(out)
end

local function bytes_to_ipv6(data, offset)
  local groups = {}
  for i = 0, 7 do
    local value, err = u16(data, offset + i * 2)
    if not value then
      return nil, err
    end
    groups[#groups + 1] = value
  end

  local best_start, best_length, current_start, current_length
  for i = 1, 9 do
    if i <= 8 and groups[i] == 0 then
      current_start = current_start or i
      current_length = (current_length or 0) + 1
    else
      if current_length and current_length >= 2 and (not best_length or current_length > best_length) then
        best_start, best_length = current_start, current_length
      end
      current_start, current_length = nil, nil
    end
  end

  if not best_start then
    local out = {}
    for i = 1, 8 do
      out[i] = string.format('%x', groups[i])
    end
    return table.concat(out, ':')
  end

  local left, right = {}, {}
  for i = 1, best_start - 1 do
    left[#left + 1] = string.format('%x', groups[i])
  end
  for i = best_start + best_length, 8 do
    right[#right + 1] = string.format('%x', groups[i])
  end
  local lhs, rhs = table.concat(left, ':'), table.concat(right, ':')
  if lhs == '' and rhs == '' then
    return '::'
  elseif lhs == '' then
    return '::' .. rhs
  elseif rhs == '' then
    return lhs .. '::'
  end
  return lhs .. '::' .. rhs
end

local function parse_question(data, offset)
  local name, next_offset, err = Codec.decode_name(data, offset)
  if not name then
    return nil, nil, err
  end
  local qtype, type_err = u16(data, next_offset)
  local qclass, class_err = u16(data, next_offset + 2)
  if not qtype or not qclass then
    return nil, nil, type_err or class_err
  end
  return {
    name = name,
    type = qtype,
    type_name = Codec.type_name(qtype),
    class = qclass,
  },
    next_offset + 4
end

local function parse_rr(data, offset)
  local name, next_offset, err = Codec.decode_name(data, offset)
  if not name then
    return nil, nil, err
  end
  local rtype, type_err = u16(data, next_offset)
  local class, class_err = u16(data, next_offset + 2)
  local ttl, ttl_err = u32(data, next_offset + 4)
  local rdlength, length_err = u16(data, next_offset + 8)
  if not rtype or not class or not ttl or not rdlength then
    return nil, nil, type_err or class_err or ttl_err or length_err
  end
  local rdata_offset = next_offset + 10
  local rdata_end = rdata_offset + rdlength - 1
  if rdata_end > #data then
    return nil, nil, 'truncated DNS resource record data'
  end

  local rr = {
    name = name,
    type = rtype,
    type_name = Codec.type_name(rtype),
    class = class,
    ttl = ttl,
    rdlength = rdlength,
    raw = string.sub(data, rdata_offset, rdata_end),
  }

  if rtype == Codec.TYPE_A then
    if rdlength ~= 4 then
      return nil, nil, 'invalid A record length'
    end
    local a, b, c, d = string.byte(data, rdata_offset, rdata_offset + 3)
    rr.address = table.concat({ a, b, c, d }, '.')
  elseif rtype == Codec.TYPE_AAAA then
    if rdlength ~= 16 then
      return nil, nil, 'invalid AAAA record length'
    end
    local address, address_err = bytes_to_ipv6(data, rdata_offset)
    if not address then
      return nil, nil, address_err
    end
    rr.address = address
  elseif rtype == Codec.TYPE_CNAME then
    local target, after, cname_err = Codec.decode_name(data, rdata_offset)
    if not target then
      return nil, nil, cname_err
    end
    if after > rdata_end + 1 then
      return nil, nil, 'CNAME data exceeds its resource record'
    end
    rr.target = target
  elseif rtype == Codec.TYPE_SOA then
    local mname, after_mname, soa_err = Codec.decode_name(data, rdata_offset)
    if not mname then
      return nil, nil, soa_err
    end
    local rname, after_rname, rname_err = Codec.decode_name(data, after_mname)
    if not rname then
      return nil, nil, rname_err
    end
    if after_rname + 19 > rdata_end then
      return nil, nil, 'truncated SOA record'
    end
    local serial = assert(u32(data, after_rname))
    local refresh = assert(u32(data, after_rname + 4))
    local retry = assert(u32(data, after_rname + 8))
    local expire = assert(u32(data, after_rname + 12))
    local minimum = assert(u32(data, after_rname + 16))
    rr.soa = {
      mname = mname,
      rname = rname,
      serial = serial,
      refresh = refresh,
      retry = retry,
      expire = expire,
      minimum = minimum,
    }
  elseif rtype == Codec.TYPE_OPT then
    rr.udp_payload_size = class
    rr.extended_rcode = math.floor(ttl / 16777216) % 256
    rr.version = math.floor(ttl / 65536) % 256
    rr.dnssec_ok = math.floor(ttl / 32768) % 2 == 1
  end

  return rr, rdata_end + 1
end

function Codec.decode_message(data, opts)
  opts = opts or {}
  if type(data) ~= 'string' then
    return nil, 'DNS message must be a string'
  end
  local maximum = tonumber(opts.max_message_size or 65535)
  if #data < 12 then
    return nil, 'DNS message is shorter than its header'
  end
  if #data > maximum then
    return nil, 'DNS message exceeds configured maximum size'
  end

  local id = assert(u16(data, 1))
  local flags = assert(u16(data, 3))
  local counts = {
    question = assert(u16(data, 5)),
    answer = assert(u16(data, 7)),
    authority = assert(u16(data, 9)),
    additional = assert(u16(data, 11)),
  }
  local max_records = tonumber(opts.max_records or 512)
  if counts.question + counts.answer + counts.authority + counts.additional > max_records then
    return nil, 'DNS message contains too many records'
  end

  local message = {
    id = id,
    flags = flags,
    qr = math.floor(flags / 32768) % 2 == 1,
    opcode = math.floor(flags / 2048) % 16,
    authoritative = math.floor(flags / 1024) % 2 == 1,
    truncated = math.floor(flags / 512) % 2 == 1,
    recursion_desired = math.floor(flags / 256) % 2 == 1,
    recursion_available = math.floor(flags / 128) % 2 == 1,
    authenticated_data = math.floor(flags / 32) % 2 == 1,
    checking_disabled = math.floor(flags / 16) % 2 == 1,
    rcode = flags % 16,
    counts = counts,
    questions = {},
    answers = {},
    authority = {},
    additional = {},
  }

  local offset = 13
  for i = 1, counts.question do
    local question, next_offset, err = parse_question(data, offset)
    if not question then
      return nil, 'question ' .. tostring(i) .. ': ' .. tostring(err)
    end
    message.questions[#message.questions + 1] = question
    offset = next_offset
  end

  local sections = {
    { count = counts.answer, target = message.answers, name = 'answer' },
    { count = counts.authority, target = message.authority, name = 'authority' },
    { count = counts.additional, target = message.additional, name = 'additional' },
  }
  for s = 1, #sections do
    local section = sections[s]
    for i = 1, section.count do
      local rr, next_offset, err = parse_rr(data, offset)
      if not rr then
        return nil, section.name .. ' record ' .. tostring(i) .. ': ' .. tostring(err)
      end
      section.target[#section.target + 1] = rr
      offset = next_offset
    end
  end

  local opt
  for i = 1, #message.additional do
    local rr = message.additional[i]
    if rr.type == Codec.TYPE_OPT then
      if opt then
        return nil, 'DNS message contains more than one OPT record'
      end
      if rr.name ~= '' then
        return nil, 'DNS OPT owner name must be the root'
      end
      opt = rr
    end
  end
  message.edns = opt
  if opt then
    message.rcode = opt.extended_rcode * 16 + message.rcode
  end
  message.trailing_bytes = #data - offset + 1
  return message
end

function Codec.encode_query(id, name, qtype, opts)
  opts = opts or {}
  id = tonumber(id)
  if not id or id < 0 or id > 65535 or id ~= math.floor(id) then
    error('DNS query id must be a 16-bit integer', 2)
  end
  name = Codec.normalise_name(name)
  qtype = normalise_type(qtype)
  local flags = opts.recursion_desired == false and 0 or 256
  local use_edns = opts.edns ~= false
  local header = table.concat({
    put_u16(id),
    put_u16(flags),
    put_u16(1),
    put_u16(0),
    put_u16(0),
    put_u16(use_edns and 1 or 0),
  })
  local question = Codec.encode_name(name) .. put_u16(qtype) .. put_u16(opts.class or Codec.CLASS_IN)
  if not use_edns then
    return header .. question
  end
  local payload = tonumber(opts.udp_payload_size or 1232)
  if not payload or payload < 512 or payload > 65535 then
    error('DNS EDNS UDP payload size must be from 512 to 65535', 2)
  end
  local ttl = opts.dnssec_ok and 32768 or 0
  local opt = '\0' .. put_u16(Codec.TYPE_OPT) .. put_u16(payload) .. put_u32(ttl) .. put_u16(0)
  return header .. question .. opt
end

local function encode_rr_name(name, first_question)
  if first_question and Codec.normalise_name(name) == Codec.normalise_name(first_question) then
    return string.char(192, 12)
  end
  return Codec.encode_name(name)
end

local function encode_rdata(rr)
  local rtype = normalise_type(rr.type or rr.type_name)
  if rtype == Codec.TYPE_A then
    return ipv4_to_bytes(rr.address)
  elseif rtype == Codec.TYPE_AAAA then
    return ipv6_to_bytes(rr.address)
  elseif rtype == Codec.TYPE_CNAME then
    return Codec.encode_name(rr.target or rr.name_target)
  elseif rtype == Codec.TYPE_SOA then
    local soa = assert(rr.soa, 'SOA record requires soa fields')
    return table.concat({
      Codec.encode_name(assert(soa.mname)),
      Codec.encode_name(assert(soa.rname)),
      put_u32(soa.serial or 0),
      put_u32(soa.refresh or 0),
      put_u32(soa.retry or 0),
      put_u32(soa.expire or 0),
      put_u32(soa.minimum or 0),
    })
  end
  return rr.raw or ''
end

local function encode_rr(rr, first_question)
  local rtype = normalise_type(rr.type or rr.type_name)
  local rdata = encode_rdata(rr)
  return table.concat({
    encode_rr_name(assert(rr.name), first_question),
    put_u16(rtype),
    put_u16(rr.class or Codec.CLASS_IN),
    put_u32(rr.ttl or 60),
    put_u16(#rdata),
    rdata,
  })
end

-- Test and embedding helper for authoritative fixtures.  It is deliberately
-- modest rather than a general DNS server encoder.
function Codec.encode_response(spec)
  spec = spec or {}
  local questions = spec.questions or {}
  local answers = spec.answers or {}
  local authority = spec.authority or {}
  local additional = spec.additional or {}
  local flags = 32768
    + (spec.authoritative and 1024 or 0)
    + (spec.truncated and 512 or 0)
    + (spec.recursion_desired == false and 0 or 256)
    + (spec.recursion_available == false and 0 or 128)
    + (tonumber(spec.rcode) or 0)
  local out = {
    put_u16(spec.id or 0),
    put_u16(flags),
    put_u16(#questions),
    put_u16(#answers),
    put_u16(#authority),
    put_u16(#additional),
  }
  for i = 1, #questions do
    local q = questions[i]
    out[#out + 1] = Codec.encode_name(q.name)
    out[#out + 1] = put_u16(normalise_type(q.type or q.type_name))
    out[#out + 1] = put_u16(q.class or Codec.CLASS_IN)
  end
  local first_question = questions[1] and questions[1].name or nil
  for _, section in ipairs({ answers, authority, additional }) do
    for i = 1, #section do
      out[#out + 1] = encode_rr(section[i], first_question)
    end
  end
  return table.concat(out)
end

function Codec.frame_tcp(message)
  if type(message) ~= 'string' or #message > 65535 then
    error('DNS TCP message must be a string of at most 65535 octets', 2)
  end
  return put_u16(#message) .. message
end

function Codec.read_u16(data, offset)
  return u16(data, offset or 1)
end

return Codec
