-- Deterministic host adapter for tests, examples and embedding sketches.
--
-- ManualHost implements the public host readiness contract without depending on
-- OS polling.  It owns a small readiness table keyed by host handle and mode;
-- block() delivers matching runtime readiness arrivals.  It is deliberately
-- level-like: readiness remains set until clear_readiness is called.

local Host = require('fibers.host')
local Handle = require('fibers.host.handle')
local HostError = require('fibers.host.error')

local Manual = {}
Manual.__index = Manual

local function normalise_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then
    mode = 'write'
  end
  if mode ~= 'read' and mode ~= 'write' then
    error('readiness mode must be read or write', 3)
  end
  return mode
end

function Manual.new(opts)
  opts = opts or {}
  local self = setmetatable({
    kind = 'manual',
    name = 'manual',
    family = 'manual',
    ready = {},
    auto_advance_time = opts.auto_advance_time ~= false,
    on_wait = opts.on_wait,
    on_wake = opts.on_wake,
    on_unsupported = opts.on_unsupported,
    _now = opts.now or 0,
    pipe_factory = opts.pipe_factory,
    listener_factory = opts.listener_factory,
    dial_factory = opts.dial_factory,
    enable_pipes = opts.pipes == true,
    enable_sockets = opts.sockets == true,
    enable_datagrams = opts.datagrams == true or opts.udp == true,
    socket_listeners = {},
    datagram_sockets = {},
    datagram_send = opts.datagram_send,
    next_ephemeral_port = opts.first_ephemeral_port or 40000,
    resolver_records = opts.resolver_records or opts.dns or {},
    enable_resolver = opts.resolver ~= false,
  }, Manual)

  self.now = function(_rt)
    return self._now
  end
  self.capabilities = {
    time = true,
    readiness = true,
    fd = false,
    pipe = self.pipe_factory ~= nil or self.enable_pipes,
    socket = self.enable_sockets,
    socket_ipv4 = self.enable_sockets,
    socket_ipv6 = self.enable_sockets,
    socket_unix = self.enable_sockets,
    datagram = self.enable_datagrams,
    datagram_truncation = self.enable_datagrams,
    resolver = self.enable_resolver,
    resolver_blocking = false,
  }
  return self
end

function Manual:create_pipe(opts)
  opts = opts or {}
  if self.pipe_factory then
    return self.pipe_factory(self, opts)
  end
  if self.enable_pipes then
    return require('fibers.host.handle').pipe_pair({ host = self, name = opts.name })
  end
  return nil, nil, require('fibers.host.error').unsupported('host', 'pipe', {
    host = self.name,
  })
end

local function socket_key(address)
  if type(address) ~= 'table' then
    return tostring(address)
  end
  if address.kind == 'unix' or address.family == 'unix' then
    return 'unix:' .. tostring(address.path)
  end
  local family = address.kind or address.family or 'inet4'
  if family == 'inet' then
    family = string.find(tostring(address.host or ''), ':', 1, true) and 'inet6' or 'inet4'
  end
  return tostring(family) .. ':' .. tostring(address.host or '0.0.0.0') .. ':' .. tostring(address.port or 0)
end

local function copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function wildcard_datagram_key(address)
  if address.kind == 'inet6' or address.family == 'inet6' then
    return socket_key({ kind = 'inet6', host = '::', port = address.port })
  end
  return socket_key({ kind = 'inet4', host = '0.0.0.0', port = address.port })
end

local function connection_pair(host, name)
  local c2s_reader, c2s_writer = Handle.pipe_pair({ host = host, name = name .. ':c2s' })
  local s2c_reader, s2c_writer = Handle.pipe_pair({ host = host, name = name .. ':s2c' })
  local client = Handle.duplex(s2c_reader, c2s_writer, {
    host = host,
    name = name .. ':client',
  })
  local server = Handle.duplex(c2s_reader, s2c_writer, {
    host = host,
    name = name .. ':server',
  })
  return client, server
end

function Manual:create_datagram(address, opts)
  opts = opts or {}
  if not self.enable_datagrams then
    return nil, HostError.unsupported('host', 'datagram', { host = self.name, address = address })
  end
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    return nil, HostError.unsupported('datagram', 'address_family', { address = address })
  end

  local actual = copy_table(address)
  if tonumber(actual.port) == 0 then
    actual.port = self.next_ephemeral_port
    self.next_ephemeral_port = self.next_ephemeral_port + 1
  end
  local key = socket_key(actual)
  if self.datagram_sockets[key] then
    return nil,
      HostError.system('datagram', 'bind', 'address already in use', 'EADDRINUSE', nil, {
        address = actual,
      })
  end

  local incoming = {}
  local handle
  handle = Handle.new({
    name = opts.name or ('manual-datagram:' .. key),
    key = 'manual-datagram-readiness:' .. key,
    host = self,
    capabilities = {
      read = false,
      write = false,
      shutdown_read = false,
      shutdown_write = false,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    close = function(self_handle)
      if handle.closed then
        return true
      end
      handle.closed = true
      self.datagram_sockets[key] = nil
      incoming = {}
      self_handle:mark_readable()
      self_handle:mark_writable()
      return true
    end,
  })
  handle.address = actual
  handle.local_address = function()
    return copy_table(actual)
  end
  handle._incoming_datagrams = incoming

  function handle:recv_from(max_size)
    self:clear_readable()
    if self.closed then
      return nil, HostError.closed('datagram', 'receive_from')
    end
    local packet = table.remove(incoming, 1)
    if not packet then
      return nil, HostError.would_block('datagram', 'receive_from')
    end
    if #incoming > 0 then
      self:mark_readable()
    end
    max_size = math.max(0, math.floor(tonumber(max_size) or 65535))
    if #packet.data > max_size then
      packet.original_size = #packet.data
      packet.data = string.sub(packet.data, 1, max_size)
      packet.truncated = true
    end
    return packet
  end

  function handle:send_to(data, destination)
    self:clear_writable()
    if self.closed then
      return nil, HostError.closed('datagram', 'send_to')
    end
    if type(self.host.datagram_send) == 'function' then
      local result, err = self.host.datagram_send(self.host, self, data, destination)
      if result == false then
        self:mark_writable()
        return #data
      elseif result == nil and err ~= nil then
        return nil, HostError.normalise(err, { domain = 'datagram', action = 'send_to' })
      end
    end
    local destination_handle = self.host.datagram_sockets[socket_key(destination)]
      or self.host.datagram_sockets[wildcard_datagram_key(destination)]
    if destination_handle and not destination_handle.closed then
      local packet = {
        data = data,
        peer = copy_table(actual),
        local_address = destination_handle:local_address(),
        truncated = false,
        flags = {},
      }
      local queue = destination_handle._incoming_datagrams
      queue[#queue + 1] = packet
      destination_handle:mark_readable()
    end
    self:mark_writable()
    return #data
  end

  self.datagram_sockets[key] = handle
  handle:mark_writable()
  return handle
end

function Manual:deliver_datagram(address, data, peer, fields)
  local handle = self.datagram_sockets[socket_key(address)]
    or self.datagram_sockets[wildcard_datagram_key(address)]
  if not handle or handle.closed then
    return nil, HostError.closed('datagram', 'deliver', { address = address })
  end
  local packet = copy_table(fields)
  packet.data = assert(data, 'datagram data required')
  packet.peer = copy_table(peer or { kind = 'inet4', family = 'inet4', host = '127.0.0.1', port = 53 })
  packet.local_address = handle:local_address()
  packet.truncated = packet.truncated == true
  packet.flags = packet.flags or {}
  local queue = handle._incoming_datagrams
  queue[#queue + 1] = packet
  handle:mark_readable()
  return true
end

function Manual:create_listener(address, opts)
  opts = opts or {}
  if self.listener_factory then
    return self.listener_factory(self, address, opts)
  end
  if not self.enable_sockets then
    return nil, HostError.unsupported('host', 'listen', { host = self.name, address = address })
  end
  local actual = {}
  for k, v in pairs(address or {}) do
    actual[k] = v
  end
  if actual.kind ~= 'unix' and tonumber(actual.port) == 0 then
    actual.port = self.next_ephemeral_port
    self.next_ephemeral_port = self.next_ephemeral_port + 1
  end
  local key = socket_key(actual)
  if self.socket_listeners[key] then
    return nil, HostError.system('socket', 'listen', 'address already in use', 'EADDRINUSE')
  end
  local pending = {}
  local listener
  listener = Handle.new({
    name = opts.name or ('manual-listener:' .. key),
    key = 'manual-listener-readiness:' .. key,
    host = self,
    capabilities = {
      read = false,
      write = false,
      shutdown_read = false,
      shutdown_write = false,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    close = function(self_handle)
      if listener.closed then
        return true
      end
      listener.closed = true
      self.socket_listeners[key] = nil
      self_handle:mark_readable()
      while #pending > 0 do
        local item = table.remove(pending, 1)
        if item.handle then
          item.handle:close('listener closed before accept')
        end
      end
      return true
    end,
  })
  listener.address = actual
  listener.pending = pending
  listener.local_address = function()
    return actual
  end
  listener.accept = function(self_listener)
    if #pending == 0 then
      if listener.closed then
        return nil, nil, HostError.closed('socket', 'accept')
      end
      self_listener:clear_readable()
      return nil, nil, HostError.would_block('socket', 'accept')
    end
    local item = table.remove(pending, 1)
    if #pending == 0 then
      self_listener:clear_readable()
    end
    return item.handle, item.peer
  end
  listener.enqueue = function(self_listener, handle, peer)
    if listener.closed then
      handle:close('listener closed')
      return nil, HostError.closed('socket', 'connect')
    end
    pending[#pending + 1] = { handle = handle, peer = peer }
    self_listener:mark_readable()
    return true
  end
  self.socket_listeners[key] = listener
  return listener
end

function Manual:dial_socket(address, opts)
  opts = opts or {}
  if not self.enable_sockets then
    return nil, nil, HostError.unsupported('host', 'dial', { host = self.name, address = address })
  end
  local key = socket_key(address)
  local listener = self.socket_listeners[key]
  if not listener and type(address) == 'table' and address.kind ~= 'unix' then
    listener = self.socket_listeners[socket_key({
      kind = 'inet4',
      family = 'inet4',
      host = '0.0.0.0',
      port = address.port,
    })] or self.socket_listeners[socket_key({
      kind = 'inet6',
      family = 'inet6',
      host = '::',
      port = address.port,
    })]
  end
  if not listener then
    return nil, nil, HostError.system('socket', 'connect', 'connection refused', 'ECONNREFUSED')
  end
  local client, server = connection_pair(self, opts.name or ('manual-connection:' .. key))
  local client_address = opts.local_address
    or {
      kind = address.kind == 'inet6' and 'inet6' or 'inet4',
      family = address.kind == 'inet6' and 'inet6' or 'inet4',
      host = address.kind == 'inet6' and '::1' or '127.0.0.1',
      port = 0,
    }
  client_address = copy_table(client_address)
  if client_address.kind ~= 'unix' and tonumber(client_address.port) == 0 then
    client_address.port = self.next_ephemeral_port
    self.next_ephemeral_port = self.next_ephemeral_port + 1
  end
  client.local_address = function()
    return copy_table(client_address)
  end
  client.peer_address_value = function()
    return copy_table(listener:local_address())
  end
  local ok, err = listener:enqueue(server, client_address)
  if not ok then
    client:close('listener rejected connection')
    return nil, nil, err
  end
  return client, listener:local_address()
end

function Manual:start_dial(address, opts)
  if self.dial_factory then
    return self.dial_factory(self, address, opts or {})
  end
  local handle, peer, err = self:dial_socket(address, opts)
  if not handle then
    return nil, err
  end
  handle.finish_connect = function(self_handle)
    return self_handle, peer
  end
  return handle
end

local function copy_address(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

function Manual:resolve(endpoint, opts)
  opts = opts or {}
  if not self.enable_resolver then
    return nil, HostError.unsupported('host', 'resolve', { host = self.name, endpoint = endpoint })
  end
  local host = endpoint.host
  local service = endpoint.service
  local record = self.resolver_records[host]
  local out = {}
  local family = opts.family or endpoint.family_hint

  local function add(address)
    if family == nil or family == 'unspec' or address.kind == family or address.family == family then
      local copied = copy_address(address)
      copied.port = copied.port or tonumber(service) or service
      out[#out + 1] = copied
    end
  end

  if type(record) == 'table' then
    for i = 1, #record do
      add(record[i])
    end
  elseif host == 'localhost' then
    add({ kind = 'inet6', family = 'inet6', host = '::1', port = tonumber(service) or service })
    add({ kind = 'inet4', family = 'inet4', host = '127.0.0.1', port = tonumber(service) or service })
  elseif type(host) == 'string' and host:match('^%d+%.%d+%.%d+%.%d+$') then
    add({ kind = 'inet4', family = 'inet4', host = host, port = tonumber(service) or service })
  elseif type(host) == 'string' and string.find(host, ':', 1, true) then
    add({ kind = 'inet6', family = 'inet6', host = host, port = tonumber(service) or service })
  end

  if #out == 0 then
    return nil,
      HostError.system('resolver', 'resolve', 'name or service not known', 'EAI_NONAME', nil, {
        endpoint = endpoint,
      })
  end
  return out
end

function Manual:set_time(t)
  self._now = tonumber(t) or self._now
  return self._now
end

function Manual:advance(dt)
  self._now = self._now + (tonumber(dt) or 0)
  return self._now
end

function Manual:set_readiness(key, mode, value)
  mode = normalise_mode(mode)
  local k = tostring(key)
  self.ready[k] = self.ready[k] or {}
  if value == false or value == nil then
    self.ready[k][mode] = nil
  else
    self.ready[k][mode] = true
  end
  return true
end

function Manual:ready(key, mode)
  return self:set_readiness(key, mode or 'read', true)
end

function Manual:readable(key)
  return self:set_readiness(key, 'read', true)
end

function Manual:writable(key)
  return self:set_readiness(key, 'write', true)
end

function Manual:clear_readiness(key, mode)
  local k = tostring(key)
  if not self.ready[k] then
    return true
  end
  if mode == nil then
    self.ready[k] = nil
  else
    self.ready[k][normalise_mode(mode)] = nil
  end
  return true
end

function Manual:is_ready(key, mode)
  local rec = self.ready[tostring(key)]
  return not not (rec and rec[normalise_mode(mode)])
end

function Manual:block(rt, waits, status, opts)
  opts = opts or {}
  waits = waits or {}

  local delivered = Host.deliver_ready(rt, waits, function(key, mode)
    return self:is_ready(key, mode)
  end)
  local poller_delivered = 0
  local poller_waits = Host.poller_waits(waits)
  for i = 1, #poller_waits do
    local wait = poller_waits[i]
    local registrations = wait.poller:_host_active()
    for j = 1, #registrations do
      local registration = registrations[j]
      if self:is_ready(registration.key, registration.mode) and wait.poller:_host_delivered(registration) then
        Host.deliver_poller_ready(rt, wait, registration)
        poller_delivered = poller_delivered + 1
      end
    end
  end
  delivered = (delivered or 0) + poller_delivered
  if delivered > 0 then
    if self.on_wake then
      self.on_wake('readiness', waits, status)
    end
    return true, 'readiness'
  end

  local deadline = Host.earliest_deadline(waits)
  if deadline ~= nil then
    if self.auto_advance_time and opts.auto_advance_time ~= false then
      if self._now < deadline then
        if self.on_wait then
          self.on_wait(deadline, deadline - self._now, waits, status)
        end
        self._now = deadline
      end
      if self.on_wake then
        self.on_wake('time', waits, status)
      end
      return true, 'time'
    end
    return nil, 'time-not-ready'
  end

  if self.on_unsupported then
    self.on_unsupported(waits, status)
  end
  if Host.has_readiness_waits(waits) or Host.has_poller_waits(waits) then
    return nil, 'readiness-not-ready'
  end
  return nil, 'unsupported-waits'
end

return Manual
