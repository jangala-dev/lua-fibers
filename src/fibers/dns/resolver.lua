-- Non-blocking DNS stub resolver built from Fibers UDP, TCP, timers and tasks.
--
-- This module performs ordinary recursive-desired DNS queries against configured
-- recursive name servers.  It does not call getaddrinfo and does not implement
-- recursion itself.  UDP is attempted first; truncated responses fall back to
-- length-framed DNS over TCP.  A and AAAA questions are run concurrently.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Sleep = require('fibers.sleep')
local Scalar = require('fibers.resource.scalar')
local StateMachine = require('fibers.resource.machine')
local Address = require('fibers.socket.address')
local Datagram = require('fibers.socket.datagram')
local Dial = require('fibers.socket.dial')
local HostError = require('fibers.host.error')
local Codec = require('fibers.dns.codec')
local Config = require('fibers.dns.config')
local File = require('fibers.file')
local IO = require('fibers.host.io')
local Protected = require('fibers.protected')
local perform = require('fibers.perform')

local Resolver = {}
Resolver.__index = Resolver

local next_resolver = 0
local weak_id_counter = 0

local LoadClaim = StateMachine.isolated_update('dns.load_once.claim', function(current)
  if current == 'idle' then
    return StateMachine.Ready.write('loading', true)
  end
  if current == 'loaded' then
    return StateMachine.Ready.same(false)
  end
  return StateMachine.Wait
end)

local LoadFinish = StateMachine.update('dns.load_once.finish', function(current)
  if current ~= 'loading' then
    return StateMachine.Wait
  end
  return StateMachine.Ready.write('loaded', true)
end)

local LoadReset = StateMachine.update('dns.load_once.reset', function(current)
  if current ~= 'loading' then
    return StateMachine.Ready.same(false)
  end
  return StateMachine.Ready.write('idle', true)
end)

local function load_once(gate, loader)
  local leader = perform(gate:transition_op(LoadClaim))
  if not leader then
    return true
  end
  local rt = Runtime.current()
  local ok, a, b = Protected.pcall(loader)
  if not ok then
    if rt then
      IO.masked_perform(rt, gate:transition_op(LoadReset))
    end
    error(a, 0)
  end
  IO.masked_perform(rt, gate:transition_op(LoadFinish))
  return true, a, b
end

local function copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function copy_list(values)
  local out = {}
  for i = 1, #(values or {}) do
    out[i] = values[i]
  end
  return out
end

local function copy_error(err)
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

local function error_value(kind, code, message, fields)
  fields = copy_table(fields)
  fields.code = code
  fields.message = message
  fields.dns_kind = kind
  if kind == 'temporary' or kind == 'timeout' then
    fields.temporary = true
  end
  return HostError.system('dns', 'resolve', message, code, nil, fields)
end

local function invalid_argument(message, fields)
  fields = copy_table(fields)
  fields.message = message
  return HostError.invalid_argument('dns', 'resolve', fields)
end

local function protocol_error(message, fields)
  return HostError.protocol('dns', 'resolve', message, fields)
end

local function normalise_name(name)
  local ok, result = pcall(Codec.normalise_name, name)
  if not ok then
    return nil, invalid_argument(tostring(result), { host = name })
  end
  return result
end

local function numeric_service(service)
  local port = tonumber(service)
  if not port or port < 0 or port > 65535 or port ~= math.floor(port) then
    return nil,
      invalid_argument('Fibers DNS resolution requires a numeric service or port', {
        service = service,
      })
  end
  return port
end

local function add_host_record(records, name, address)
  name = string.lower((name or ''):gsub('%.$', ''))
  if name == '' then
    return
  end
  records[name] = records[name] or {}
  local kind = string.find(address, ':', 1, true) and 'inet6' or 'inet4'
  records[name][#records[name] + 1] = { kind = kind, family = kind, host = address }
end

local function parse_hosts(text)
  local records = {}
  for raw in string.gmatch((text or '') .. '\n', '([^\n]*)\n') do
    local line = raw:gsub('#.*$', '')
    local words = {}
    for word in string.gmatch(line, '%S+') do
      words[#words + 1] = word
    end
    local address = words[1]
    if address and (address:match('^%d+%.%d+%.%d+%.%d+$') or address:find(':', 1, true)) then
      for i = 2, #words do
        add_host_record(records, words[i], address)
      end
    end
  end
  return records
end

local function explicit_hosts(values)
  local records = {}
  for name, entries in pairs(values or {}) do
    if type(entries) ~= 'table' or entries.kind or entries.family then
      entries = { entries }
    end
    for i = 1, #entries do
      local entry = entries[i]
      if type(entry) == 'string' then
        add_host_record(records, name, entry)
      elseif type(entry) == 'table' and entry.host then
        add_host_record(records, name, entry.host)
      end
    end
  end
  return records
end

local function merge_hosts(left, right)
  for name, entries in pairs(right or {}) do
    left[name] = left[name] or {}
    for i = 1, #entries do
      left[name][#left[name] + 1] = entries[i]
    end
  end
  return left
end

local function ensure_localhost(records)
  if not records.localhost then
    records.localhost = {
      { kind = 'inet6', family = 'inet6', host = '::1' },
      { kind = 'inet4', family = 'inet4', host = '127.0.0.1' },
    }
  end
  return records
end

local function initial_hosts(opts)
  local records = explicit_hosts(opts.hosts)
  local loaded = opts.read_hosts == false
  if opts.hosts_file ~= nil then
    merge_hosts(records, parse_hosts(opts.hosts_file))
    loaded = true
  end
  if loaded then
    ensure_localhost(records)
  end
  return records, loaded
end

local function secure_random_u16(self)
  local file, open_err = File.open(self.opts.random_path or '/dev/urandom', 'rb', {
    name = self.name .. ':entropy',
  })
  if not file then
    return nil, open_err
  end
  local bytes, read_err = file:read_exactly(2)
  local closed, close_err = file:close('DNS transaction ID acquired')
  if type(bytes) ~= 'string' or #bytes ~= 2 then
    return nil, read_err or close_err or 'short entropy read'
  end
  if not closed then
    return nil, close_err
  end
  local a, b = string.byte(bytes, 1, 2)
  return a * 256 + b
end

local function weak_random_u16()
  weak_id_counter = weak_id_counter + 1
  local rt = Runtime.current()
  local now = rt and rt:now() or 0
  local random = math.random and math.random(0, 65535) or 0
  return (weak_id_counter * 40503 + math.floor(now * 1000003) + random) % 65536
end

local function next_id(self)
  if type(self.random_u16) == 'function' then
    local value = tonumber(self.random_u16(self))
    if value and value >= 0 and value <= 65535 then
      return math.floor(value)
    end
    error('DNS random_u16 callback returned an invalid value', 2)
  end
  local value, entropy_err = secure_random_u16(self)
  if value then
    self.secure_ids = true
    return value
  end
  self.secure_ids = false
  local allow_weak = self.opts.allow_weak_random == true or self.opts.require_secure_random == false
  if not allow_weak then
    return nil,
      HostError.unsupported('dns', 'secure_random', {
        code = 'dns_secure_random_unavailable',
        message = 'secure DNS transaction-ID entropy is unavailable',
        cause = entropy_err,
      })
  end
  return weak_random_u16()
end

local function same_question(message, id, name, qtype)
  if not message.qr or message.opcode ~= 0 or message.id ~= id then
    return false
  end
  if #message.questions ~= 1 then
    return false
  end
  local question = message.questions[1]
  local qname = normalise_name(question.name)
  return qname == name and question.type == qtype and question.class == Codec.CLASS_IN
end

local function minimum(a, b)
  if a == nil then
    return b
  end
  if b == nil then
    return a
  end
  return math.min(a, b)
end

local function perform_before(op, deadline)
  return perform(op:or_else(Sleep.sleep_until_op(deadline):map(function()
    return nil, error_value('timeout', 'ETIMEDOUT', 'DNS TCP transaction timed out')
  end)))
end

local function close_quietly(value, reason)
  if value and type(value.close) == 'function' then
    Protected.pcall(value.close, value, reason)
  end
end

function Resolver.new(opts)
  opts = copy_table(opts)
  local maximum_cache_entries = opts.maximum_cache_entries
  if maximum_cache_entries == nil then
    maximum_cache_entries = 1024
  end
  maximum_cache_entries = tonumber(maximum_cache_entries)
  if
    not maximum_cache_entries
    or maximum_cache_entries ~= math.floor(maximum_cache_entries)
    or maximum_cache_entries < 0
  then
    error('maximum_cache_entries must be a non-negative integer', 2)
  end
  opts.maximum_cache_entries = maximum_cache_entries
  next_resolver = next_resolver + 1
  local hosts, hosts_loaded = initial_hosts(opts)
  local self = setmetatable({
    name = opts.name or ('dns-resolver-' .. tostring(next_resolver)),
    opts = opts,
    host = opts.host,
    config = nil,
    config_error = nil,
    cache = {},
    cache_order = {},
    no_edns = {},
    hosts = hosts,
    hosts_loaded = hosts_loaded,
    hosts_error = nil,
    hosts_load = StateMachine.new(hosts_loaded and 'loaded' or 'idle', 'dns:hosts-load'),
    config_load = StateMachine.new('idle', 'dns:config-load'),
    random_u16 = opts.random_u16,
    secure_ids = nil,
  }, Resolver)
  if opts.nameservers or opts.nameserver or opts.resolv_conf then
    local config, err = Config.load(opts)
    self.config, self.config_error = config, err
    self.config_load = StateMachine.new('loaded', 'dns:config-load')
  end
  return self
end

function Resolver:_load_hosts()
  load_once(self.hosts_load, function()
    local text, err = File.read_all(self.opts.hosts_path or '/etc/hosts', {
      max = tonumber(self.opts.maximum_hosts_size) or 1024 * 1024,
      name = self.name .. ':read-hosts',
    })
    if text then
      merge_hosts(self.hosts, parse_hosts(text))
    else
      self.hosts_error = err
    end
    ensure_localhost(self.hosts)
    self.hosts_loaded = true
  end)
  return self.hosts, self.hosts_error
end

function Resolver:_load_config()
  load_once(self.config_load, function()
    local config, err = Config.load(self.opts)
    self.config, self.config_error = config, err
  end)
  if not self.config then
    return nil,
      HostError.unsupported('dns', 'configuration', {
        code = 'dns_no_nameserver',
        message = tostring(self.config_error),
      })
  end
  return self.config
end

function Resolver:configuration()
  return self:_load_config()
end

function Resolver:has_static_name(name)
  self:_load_hosts()
  local normalised = normalise_name(name)
  if not normalised then
    return false
  end
  return self.hosts[normalised] ~= nil
    or normalised:match('^%d+%.%d+%.%d+%.%d+$') ~= nil
    or string.find(normalised, ':', 1, true) ~= nil
end

function Resolver:clear_cache()
  self.cache = {}
  self.cache_order = {}
  return true
end

function Resolver:_now()
  local rt = Runtime.current()
  return rt and rt:now() or 0
end

function Resolver:_cache_key(name, qtype)
  return name .. '|' .. tostring(qtype)
end

function Resolver:_cache_get(name, qtype)
  local now = self:_now()
  for _, key in ipairs({ self:_cache_key(name, qtype), self:_cache_key(name, '*') }) do
    local item = self.cache[key]
    if item then
      if item.expires_at <= now then
        self.cache[key] = nil
      else
        return item
      end
    end
  end
  return nil
end

function Resolver:_compact_cache()
  local now, order, seen = self:_now(), {}, {}
  for i = 1, #self.cache_order do
    local key = self.cache_order[i]
    local item = self.cache[key]
    if item and item.expires_at > now and not seen[key] then
      seen[key] = true
      order[#order + 1] = key
    elseif item and item.expires_at <= now then
      self.cache[key] = nil
    end
  end
  self.cache_order = order
  return order
end

function Resolver:_cache_put(name, qtype, item, ttl)
  ttl = tonumber(ttl) or 0
  local cap = tonumber(self.opts.maximum_ttl or 86400)
  ttl = math.min(math.max(0, ttl), cap)
  local maximum = self.opts.maximum_cache_entries
  if ttl <= 0 or maximum <= 0 then
    return
  end

  local key = self:_cache_key(name, qtype)
  local order = self:_compact_cache()
  if not self.cache[key] then
    while #order >= maximum do
      local evicted = table.remove(order, 1)
      self.cache[evicted] = nil
    end
    order[#order + 1] = key
  end
  item.expires_at = self:_now() + ttl
  self.cache[key] = item
end

local function server_local_address(server)
  if server.kind == 'inet6' then
    return Address.ipv6('::', 0)
  end
  return Address.ipv4('0.0.0.0', 0)
end

local function classify_udp_packet(packet, server, id, name, qtype, opts)
  if not packet.peer or not Address.equal(packet.peer, server) then
    return { kind = 'ignore' }
  end
  local message, decode_err = Codec.decode_message(packet.data, {
    max_message_size = opts.maximum_message_size or 65535,
    max_records = opts.maximum_records or 512,
  })
  if not message then
    return {
      kind = 'invalid',
      error = decode_err or (packet.truncated and 'locally truncated DNS response could not be validated'),
    }
  end
  if not same_question(message, id, name, qtype) then
    return { kind = 'invalid', error = 'DNS response did not match the outstanding question' }
  end
  if message.truncated then
    return { kind = 'tcp', message = message }
  end
  return { kind = 'answer', message = message }
end

Resolver.classify_udp_packet = classify_udp_packet

function Resolver:_udp_exchange(server, wire, id, name, qtype, timeout, opts)
  local socket, open_err = perform(Datagram.udp_op(server_local_address(server), {
    host = opts.host or self.host,
    name = self.name .. ':udp',
    receive_capacity = opts.receive_capacity or 16,
    send_capacity = opts.send_capacity or 4,
    max_datagram_size = opts.maximum_message_size or 65535,
  }))
  if not socket then
    return nil, HostError.normalise(open_err, { domain = 'dns', action = 'udp_open', server = server })
  end

  local sent, send_err = socket:send_to(wire, server)
  if not sent then
    close_quietly(socket, 'DNS UDP send failed')
    return nil, HostError.normalise(send_err, { domain = 'dns', action = 'udp_send', server = server })
  end
  local flushed, flush_err = socket:flush()
  if not flushed then
    close_quietly(socket, 'DNS UDP flush failed')
    return nil, HostError.normalise(flush_err, { domain = 'dns', action = 'udp_send', server = server })
  end

  local rt = Runtime.current()
  local deadline = rt:now() + timeout
  local last_protocol
  while true do
    local kind, packet, receive_err = perform(socket
      :receive_from_op({ max_size = opts.maximum_message_size or 65535 })
      :map(function(value, err)
        return 'packet', value, err
      end)
      :or_else(Sleep.sleep_until_op(deadline):map(function()
        return 'timeout'
      end)))

    if kind == 'timeout' then
      close_quietly(socket, 'DNS UDP timeout')
      return nil,
        error_value('timeout', 'ETIMEDOUT', 'DNS query timed out', {
          server = server,
          name = name,
          qtype = qtype,
          cause = last_protocol,
        })
    end
    if not packet then
      close_quietly(socket, 'DNS UDP receive failed')
      return nil,
        HostError.normalise(receive_err, { domain = 'dns', action = 'udp_receive', server = server })
    end
    local decision = classify_udp_packet(packet, server, id, name, qtype, opts)
    if decision.kind == 'answer' then
      close_quietly(socket, 'DNS UDP complete')
      return decision.message
    elseif decision.kind == 'tcp' then
      close_quietly(socket, 'DNS UDP truncated')
      return { truncated = true }
    elseif decision.kind == 'invalid' then
      last_protocol = decision.error
    end
  end
end

function Resolver:_tcp_exchange(server, wire, id, name, qtype, timeout, opts)
  local dial, dial_err = perform(Dial.dial_op(server, {
    host = opts.host or self.host,
    name = self.name .. ':tcp-dial',
    read_capacity = opts.tcp_read_capacity,
    write_capacity = opts.tcp_write_capacity,
  }))
  if not dial then
    return nil, HostError.normalise(dial_err, { domain = 'dns', action = 'tcp_dial', server = server })
  end
  local deadline = Runtime.current():now() + (tonumber(opts.tcp_timeout) or timeout or 5.0)
  local connection, connect_err = perform_before(dial:result_op(), deadline)
  if not connection then
    close_quietly(dial, 'DNS TCP dial failed')
    return nil, HostError.normalise(connect_err, { domain = 'dns', action = 'tcp_dial', server = server })
  end

  local written, write_err = perform_before(connection:write_op(Codec.frame_tcp(wire)), deadline)
  if not written then
    close_quietly(connection, 'DNS TCP write failed')
    close_quietly(dial, 'DNS TCP write failed')
    return nil, HostError.normalise(write_err, { domain = 'dns', action = 'tcp_write', server = server })
  end
  local flushed, flush_err = perform_before(connection:flush_op(), deadline)
  if not flushed then
    close_quietly(connection, 'DNS TCP flush failed')
    close_quietly(dial, 'DNS TCP flush failed')
    return nil, HostError.normalise(flush_err, { domain = 'dns', action = 'tcp_write', server = server })
  end

  local prefix, prefix_err = perform_before(connection:read_exactly_op(2), deadline)
  if not prefix then
    close_quietly(connection, 'DNS TCP prefix failed')
    close_quietly(dial, 'DNS TCP prefix failed')
    return nil, HostError.normalise(prefix_err, { domain = 'dns', action = 'tcp_read', server = server })
  end
  local length = Codec.read_u16(prefix, 1)
  local maximum = tonumber(opts.maximum_tcp_message_size or 65535)
  if not length or length < 12 or length > maximum then
    close_quietly(connection, 'invalid DNS TCP length')
    close_quietly(dial, 'invalid DNS TCP length')
    return nil, protocol_error('invalid DNS TCP message length', { server = server, length = length })
  end
  local data, read_err = perform_before(connection:read_exactly_op(length), deadline)
  close_quietly(connection, 'DNS TCP complete')
  close_quietly(dial, 'DNS TCP complete')
  if not data then
    return nil, HostError.normalise(read_err, { domain = 'dns', action = 'tcp_read', server = server })
  end
  local message, decode_err = Codec.decode_message(data, {
    max_message_size = maximum,
    max_records = opts.maximum_records or 512,
  })
  if not message then
    return nil, protocol_error(tostring(decode_err), { server = server })
  end
  if not same_question(message, id, name, qtype) then
    return nil,
      protocol_error('DNS TCP response does not match the outstanding question', { server = server })
  end
  return message
end

function Resolver:_exchange(name, qtype, opts)
  local config, config_err = self:_load_config()
  if not config then
    return nil, config_err
  end
  local attempts = tonumber(opts.attempts or config.attempts) or 2
  local base_timeout = tonumber(opts.timeout or config.timeout) or 1.0
  local last_err

  for attempt = 1, math.max(1, math.floor(attempts)) do
    local timeout = math.min(base_timeout * (2 ^ (attempt - 1)), tonumber(opts.maximum_timeout or 5.0))
    for i = 1, #config.nameservers do
      local server = config.nameservers[i]
      local server_key = Address.key(server)
      local use_edns = opts.edns ~= false and self.opts.edns ~= false and not self.no_edns[server_key]
      local retried_without_edns = false
      while true do
        local id, id_err = next_id(self)
        if not id then
          return nil, id_err
        end
        local wire = Codec.encode_query(id, name, qtype, {
          udp_payload_size = opts.udp_payload_size or self.opts.udp_payload_size or 1232,
          edns = use_edns,
          dnssec_ok = opts.dnssec_ok == true or self.opts.dnssec_ok == true,
        })
        local message, err = self:_udp_exchange(server, wire, id, name, qtype, timeout, opts)
        if message then
          if message.truncated then
            message, err = self:_tcp_exchange(server, wire, id, name, qtype, timeout, opts)
          end
          if message then
            if
              use_edns
              and not retried_without_edns
              and (
                message.rcode == Codec.RCODE.FORMERR
                or message.rcode == Codec.RCODE.NOTIMP
                or message.rcode == 16
              )
            then
              self.no_edns[server_key] = true
              use_edns = false
              retried_without_edns = true
            else
              return message
            end
          else
            last_err = err
            break
          end
        else
          last_err = err
          break
        end
      end
    end
  end

  return nil,
    last_err or error_value('temporary', 'EAI_AGAIN', 'all configured DNS name servers failed', {
      name = name,
      qtype = qtype,
    })
end

local function negative_ttl(message)
  local ttl
  for i = 1, #message.authority do
    local rr = message.authority[i]
    if rr.type == Codec.TYPE_SOA and rr.soa then
      ttl = minimum(ttl, math.min(rr.ttl or 0, rr.soa.minimum or 0))
    end
  end
  return ttl
end

local function rcode_error(message, name, qtype)
  local rcode = message.rcode
  if rcode == Codec.RCODE.NXDOMAIN then
    return error_value('not_found', 'EAI_NONAME', 'DNS name does not exist', {
      name = name,
      qtype = qtype,
      rcode = rcode,
    })
  elseif rcode == Codec.RCODE.SERVFAIL then
    return error_value('temporary', 'EAI_AGAIN', 'DNS server failure', {
      name = name,
      qtype = qtype,
      rcode = rcode,
    })
  elseif rcode == Codec.RCODE.REFUSED then
    return error_value('refused', 'EAI_FAIL', 'DNS query was refused', {
      name = name,
      qtype = qtype,
      rcode = rcode,
    })
  elseif rcode ~= Codec.RCODE.NOERROR then
    return error_value('failure', 'EAI_FAIL', 'DNS query failed with rcode ' .. tostring(rcode), {
      name = name,
      qtype = qtype,
      rcode = rcode,
    })
  end
end

local function matching_records(message, owner, rtype)
  local out = {}
  owner = string.lower(owner)
  for i = 1, #message.answers do
    local rr = message.answers[i]
    if rr.class == Codec.CLASS_IN and string.lower(rr.name) == owner and rr.type == rtype then
      out[#out + 1] = rr
    end
  end
  return out
end

function Resolver:resolve_type(name, qtype, opts)
  opts = copy_table(opts)
  local normalised, name_err = normalise_name(name)
  if not normalised then
    return nil, name_err
  end
  qtype = Codec.type_code(qtype)

  local cached = self:_cache_get(normalised, qtype)
  if cached then
    if cached.kind == 'positive' then
      return copy_list(cached.addresses), nil, cached.canonical
    end
    return nil, copy_error(cached.error)
  end

  local original, current = normalised, normalised
  local visited, chain_ttl = {}, nil
  local maximum_cnames = tonumber(opts.maximum_cnames or self.opts.maximum_cnames or 16)
  if
    not maximum_cnames
    or maximum_cnames ~= math.floor(maximum_cnames)
    or maximum_cnames < 0
    or maximum_cnames > 64
  then
    return nil, invalid_argument('maximum_cnames must be an integer from 0 to 64', { value = maximum_cnames })
  end
  local cname_hops = 0

  while true do
    if visited[current] then
      return nil, protocol_error('DNS CNAME loop', { name = original, canonical = current })
    end
    visited[current] = true

    local message, exchange_err = self:_exchange(current, qtype, opts)
    if not message then
      return nil, exchange_err
    end
    local response_err = rcode_error(message, current, qtype)
    if response_err then
      if message.rcode == Codec.RCODE.NXDOMAIN then
        local ttl = negative_ttl(message)
        if ttl then
          self:_cache_put(original, '*', { kind = 'negative', error = copy_error(response_err) }, ttl)
        end
      end
      return nil, response_err
    end

    local owner = current
    while true do
      local records = matching_records(message, owner, qtype)
      if #records > 0 then
        local addresses, seen, ttl = {}, {}, chain_ttl
        for i = 1, #records do
          local address = records[i].address
          if address and not seen[address] then
            seen[address] = true
            addresses[#addresses + 1] = address
          end
          ttl = minimum(ttl, records[i].ttl)
        end
        if #addresses > 0 then
          self:_cache_put(original, qtype, {
            kind = 'positive',
            addresses = copy_list(addresses),
            canonical = owner,
          }, ttl or 0)
          return addresses, nil, owner
        end
      end

      local aliases = matching_records(message, owner, Codec.TYPE_CNAME)
      if #aliases == 0 then
        local err = error_value('no_data', 'EAI_NODATA', 'DNS response contains no requested records', {
          name = original,
          canonical = owner,
          qtype = qtype,
        })
        local ttl = negative_ttl(message)
        if ttl then
          self:_cache_put(original, qtype, { kind = 'negative', error = copy_error(err) }, ttl)
        end
        return nil, err
      end

      local target
      for i = 1, #aliases do
        local candidate, target_err = normalise_name(aliases[i].target)
        if not candidate then
          return nil, target_err
        end
        if target and target ~= candidate then
          return nil,
            protocol_error('DNS response contains conflicting CNAME targets', {
              name = original,
              canonical = owner,
            })
        end
        target = candidate
        chain_ttl = minimum(chain_ttl, aliases[i].ttl)
      end

      cname_hops = cname_hops + 1
      if cname_hops > maximum_cnames then
        return nil, protocol_error('DNS CNAME chain exceeds configured limit', { name = original })
      end
      if visited[target] then
        return nil, protocol_error('DNS CNAME loop', { name = original, canonical = target })
      end
      owner = target
      current = target
      if
        #matching_records(message, owner, qtype) == 0
        and #matching_records(message, owner, Codec.TYPE_CNAME) == 0
      then
        break
      end
    end
  end
end

function Resolver:_candidate_names(host, opts)
  local config = self:_load_config()
  local normalised = assert(normalise_name(host))
  if string.sub(host, -1) == '.' or not config then
    return { normalised }
  end
  local dots = 0
  for _ in string.gmatch(normalised, '%.') do
    dots = dots + 1
  end
  local search = opts.search or self.opts.search or config.search or {}
  local ndots = tonumber(opts.ndots or self.opts.ndots or config.ndots or 1)
  local names, seen = {}, {}
  local function add(value)
    if value ~= '' and not seen[value] then
      seen[value] = true
      names[#names + 1] = value
    end
  end
  if dots >= ndots then
    add(normalised)
  end
  for i = 1, #search do
    add(normalised .. '.' .. string.lower(tostring(search[i]):gsub('%.$', '')))
  end
  add(normalised)
  return names
end

function Resolver:_hosts_lookup(name, port, family)
  self:_load_hosts()
  local entries = self.hosts[string.lower(name)]
  if not entries then
    return nil
  end
  local out, seen = {}, {}
  for i = 1, #entries do
    local entry = entries[i]
    if family == nil or family == 'unspec' or family == entry.kind then
      local address = entry.kind == 'inet6' and Address.ipv6(entry.host, port)
        or Address.ipv4(entry.host, port)
      local key = Address.key(address)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = address
      end
    end
  end
  return #out > 0 and out or nil
end

function Resolver:_resolve_candidate(name, port, family, opts)
  local qtypes = {}
  if family == 'inet6' then
    qtypes[1] = Codec.TYPE_AAAA
  elseif family == 'inet4' then
    qtypes[1] = Codec.TYPE_A
  else
    qtypes[1], qtypes[2] = Codec.TYPE_AAAA, Codec.TYPE_A
  end

  local scope = Runtime.current_scope()
  if not scope then
    error('DNS resolution requires a current Fibers scope', 2)
  end
  local task_entries = {}
  for i = 1, #qtypes do
    local qtype = qtypes[i]
    local family_name = qtype == Codec.TYPE_AAAA and 'inet6' or 'inet4'
    task_entries[#task_entries + 1] = {
      family_name,
      scope:spawn_op(function()
        return self:resolve_type(name, qtype, opts)
      end, self.name .. ':' .. Codec.type_name(qtype)),
    }
  end
  local tasks = perform(Op.named_all(task_entries))

  local outcome_entries = {}
  for i = 1, #task_entries do
    local family_name = task_entries[i][1]
    outcome_entries[i] = { family_name, tasks[family_name]:outcome_op() }
  end
  local outcomes = perform(Op.named_all(outcome_entries))

  local addresses, errors, seen = {}, {}, {}
  for i = 1, #task_entries do
    local family_name = task_entries[i][1]
    local values, err = outcomes[family_name]:raise()
    if values then
      for j = 1, #values do
        local address = family_name == 'inet6' and Address.ipv6(values[j], port)
          or Address.ipv4(values[j], port)
        local key = Address.key(address)
        if not seen[key] then
          seen[key] = true
          addresses[#addresses + 1] = address
        end
      end
    else
      errors[#errors + 1] = err
    end
  end
  if #addresses > 0 then
    return addresses
  end
  return nil,
    errors[1] or error_value('not_found', 'EAI_NONAME', 'name resolved to no addresses', { name = name })
end

function Resolver:_resolve_endpoint(endpoint, opts)
  opts = copy_table(opts)
  endpoint = Address.validate(endpoint, 'DNS resolver endpoint')
  if endpoint.kind ~= 'name' then
    return nil, invalid_argument('DNS resolver expects a name endpoint', { endpoint = endpoint })
  end
  local port, service_err = numeric_service(endpoint.service)
  if not port then
    return nil, service_err
  end
  local family = opts.family or endpoint.family_hint or 'unspec'
  if family ~= 'unspec' and family ~= 'inet4' and family ~= 'inet6' then
    return nil, invalid_argument('DNS family must be inet4, inet6 or unspec', { family = family })
  end

  local host_name, name_err = normalise_name(endpoint.host)
  if not host_name then
    return nil, name_err
  end
  if host_name:match('^%d+%.%d+%.%d+%.%d+$') then
    if family == 'inet6' then
      return nil,
        error_value(
          'no_data',
          'EAI_NODATA',
          'numeric IPv4 address does not match inet6',
          { host = host_name }
        )
    end
    return { Address.ipv4(host_name, port) }
  elseif string.find(host_name, ':', 1, true) then
    if family == 'inet4' then
      return nil,
        error_value(
          'no_data',
          'EAI_NODATA',
          'numeric IPv6 address does not match inet4',
          { host = host_name }
        )
    end
    return { Address.ipv6(host_name, port) }
  end

  local hosted = self:_hosts_lookup(host_name, port, family)
  if hosted then
    return hosted
  end

  local candidates = self:_candidate_names(endpoint.host, opts)
  local last_err
  for i = 1, #candidates do
    local addresses, err = self:_resolve_candidate(candidates[i], port, family, opts)
    if addresses then
      return addresses
    end
    last_err = err
    if not (HostError.is(err, 'system') and err.code == 'EAI_NONAME') then
      -- NODATA for a search candidate is also eligible to continue to the next
      -- candidate, while transport and protocol failures are terminal.
      if not (HostError.is(err, 'system') and err.code == 'EAI_NODATA') then
        return nil, err
      end
    end
  end
  return nil, last_err
end

function Resolver:resolve_family(endpoint, family, opts)
  opts = copy_table(opts)
  opts.family = family
  return self:_resolve_endpoint(endpoint, opts)
end

function Resolver:resolve(endpoint, opts)
  return self:_resolve_endpoint(endpoint, opts)
end

Resolver.parse_hosts = parse_hosts
return Resolver
