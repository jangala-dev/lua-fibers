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
    enable_pipes = opts.pipes == true,
    enable_sockets = opts.sockets == true,
    socket_listeners = {},
    next_ephemeral_port = opts.first_ephemeral_port or 40000,
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
  return 'inet:' .. tostring(address.host or '0.0.0.0') .. ':' .. tostring(address.port or 0)
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

function Manual:create_listener(address, opts)
  opts = opts or {}
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
      kind = 'inet',
      family = 'inet',
      host = '0.0.0.0',
      port = address.port,
    })] or self.socket_listeners[socket_key({
      kind = 'inet',
      family = 'inet',
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
      kind = 'inet',
      family = 'inet',
      host = '127.0.0.1',
      port = 0,
    }
  local ok, err = listener:enqueue(server, client_address)
  if not ok then
    client:close('listener rejected connection')
    return nil, nil, err
  end
  return client, listener:local_address()
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
