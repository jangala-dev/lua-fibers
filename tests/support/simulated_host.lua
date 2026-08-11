-- Deterministic in-memory operating-system simulation for tests.

local Op = require('fibers.op')
local Completion = require('fibers.resource.completion')
local HostError = require('fibers.io.error')
local IOAudit = require('fibers.diagnostics.io')
local perform = require('fibers.perform')
local Protected = require('fibers.protected')
local WaitSet = require('fibers.embed.wait_set')
local Address = require('fibers.net.address')
local Label = require('fibers.internal.label')

local Binding = {
  name = 'simulated',
  family = 'simulated',
}

local AGAIN, CLOSED, BROKEN = 'again', 'closed', 'broken_pipe'
Binding.errors = {
  again = { [AGAIN] = true },
  closed = { [CLOSED] = true },
  broken_pipe = { [BROKEN] = true },
  message = function(code)
    return tostring(code)
  end,
  name = function(code)
    return tostring(code)
  end,
}

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function address_key(address)
  return Address.key(Address.validate(address, 'simulated socket address'))
end

local function wildcard_key(address)
  address = Address.validate(address, 'simulated socket address')
  local wildcard = address.kind == 'inet6' and Address.ipv6('::', address.port)
    or Address.ipv4('0.0.0.0', address.port)
  return Address.key(wildcard)
end

local function buffer()
  return { chunks = {}, bytes = 0, read_closed = false, write_closed = false }
end

local function update(state)
  local reader = state.reader and state.reader.handle
  if reader then
    if not state.read_closed and (state.bytes > 0 or state.write_closed) then
      reader:mark_readable()
    else
      reader:clear_readable()
    end
  end
  local writer = state.writer and state.writer.handle
  if writer then
    if state.write_closed then
      writer:clear_writable()
    else
      writer:mark_writable()
    end
  end
end

local function endpoint(host, kind, can_read, can_write)
  host._manual_serial = host._manual_serial + 1
  return {
    host = host,
    kind = kind,
    key = 'simulated-' .. kind .. '-' .. tostring(host._manual_serial),
    can_read = can_read,
    can_write = can_write,
  }
end

local function pair(host, kind)
  local left, right = endpoint(host, kind, true, true), endpoint(host, kind, true, true)
  local left_in, right_in = buffer(), buffer()
  left.rx, left.tx = left_in, right_in
  right.rx, right.tx = right_in, left_in
  left_in.reader, left_in.writer = left, right
  right_in.reader, right_in.writer = right, left
  return left, right
end

local function pipe_pair(host)
  local reader, writer = endpoint(host, 'pipe-read', true, false), endpoint(host, 'pipe-write', false, true)
  local state = buffer()
  reader.rx, writer.tx = state, state
  state.reader, state.writer = reader, writer
  return reader, writer
end

Binding.fd = {
  supported = function()
    return true
  end,
  validate = function(value)
    return assert(value, 'manual descriptor required')
  end,
  poll_value = function(value)
    return value.key
  end,
  opened = function(handle, value)
    value.handle = handle
    update(value.rx or value.tx or {})
  end,
  pipe = function(host)
    return pipe_pair(assert(host, 'simulated pipe requires host'))
  end,
  set_nonblocking = function()
    return true
  end,
  set_cloexec = function()
    return true
  end,
}

function Binding.fd.read(raw, maximum)
  local state = raw.rx
  if raw.closed or not state or state.read_closed then
    return nil, CLOSED
  end
  if state.bytes == 0 then
    if state.write_closed then
      return ''
    end
    return nil, AGAIN
  end
  local first = state.chunks[1]
  local count = math.min(tonumber(maximum) or 4096, #first)
  local data, rest = first:sub(1, count), first:sub(count + 1)
  state.bytes = state.bytes - count
  if rest == '' then
    table.remove(state.chunks, 1)
  else
    state.chunks[1] = rest
  end
  update(state)
  return data
end

function Binding.fd.write(raw, bytes)
  local state = raw.tx
  if raw.closed or not state or state.write_closed then
    return nil, CLOSED
  end
  if state.read_closed then
    return nil, BROKEN
  end
  if bytes == '' then
    return 0
  end
  state.chunks[#state.chunks + 1] = bytes
  state.bytes = state.bytes + #bytes
  update(state)
  return #bytes
end

function Binding.fd.shutdown(raw, mode)
  if mode == 'read' and raw.rx then
    raw.rx.read_closed, raw.rx.chunks, raw.rx.bytes = true, {}, 0
    update(raw.rx)
  elseif mode == 'write' and raw.tx then
    raw.tx.write_closed = true
    update(raw.tx)
  end
  return true
end

function Binding.fd.close(raw)
  if raw.closed then
    return true
  end
  raw.closed = true
  if raw.rx then
    raw.rx.read_closed, raw.rx.chunks, raw.rx.bytes = true, {}, 0
    update(raw.rx)
  end
  if raw.tx then
    raw.tx.write_closed = true
    update(raw.tx)
  end
  if raw.listener_key then
    raw.host.socket_listeners[raw.listener_key] = nil
  end
  if raw.datagram_key then
    raw.host.datagram_sockets[raw.datagram_key] = nil
  end
  return true
end

Binding.net = {
  datagram = true,
  supports = function(family)
    return family == 'inet4' or family == 'inet6' or family == 'unix'
  end,
  is_unix = function(family)
    return family == 'unix'
  end,
  unlink = function()
    return true
  end,
  encode = function(address)
    local ok, value = pcall(Address.validate, address, 'simulated socket address')
    if not ok then
      return nil, HostError.invalid_argument('socket', 'address', { address = address })
    end
    return { family = value.kind, native = value }
  end,
  decode = function(address)
    return address and Address.validate(address, 'simulated socket address') or nil
  end,
  open = function(family, kind, host)
    local raw =
      endpoint(assert(host, 'simulated socket requires host'), kind, kind == 'stream', kind == 'stream')
    raw.family, raw.socket_kind = family, kind
    if kind == 'datagram' then
      raw.incoming = {}
    end
    return raw
  end,
  set_option = function()
    return true
  end,
}

function Binding.net.bind(raw, address)
  local actual = copy(address)
  if actual.kind ~= 'unix' and actual.family ~= 'unix' and tonumber(actual.port) == 0 then
    actual.port = raw.host.next_ephemeral_port
    raw.host.next_ephemeral_port = raw.host.next_ephemeral_port + 1
  end
  local key = address_key(actual)
  local registry = raw.socket_kind == 'datagram' and raw.host.datagram_sockets or raw.host.socket_listeners
  if registry[key] then
    return nil, 'EADDRINUSE', 'address already in use'
  end
  raw.address, raw.bound_key = actual, key
  if raw.socket_kind == 'datagram' then
    raw.datagram_key = key
    registry[key] = raw
  end
  return true
end

function Binding.net.listen(raw)
  raw.pending = {}
  raw.listener_key = raw.bound_key
  raw.host.socket_listeners[raw.listener_key] = raw
  return true
end

function Binding.net.accept(raw)
  if raw.closed then
    return nil, nil, CLOSED
  end
  local item = table.remove(raw.pending or {}, 1)
  if not item then
    if raw.handle then
      raw.handle:clear_readable()
    end
    return nil, nil, AGAIN
  end
  if #raw.pending == 0 and raw.handle then
    raw.handle:clear_readable()
  end
  return item.raw, copy(item.peer)
end

function Binding.net.connect(raw, address)
  local host = raw.host
  local listener = host.socket_listeners[address_key(address)]
  if not listener and address.kind ~= 'unix' and address.family ~= 'unix' then
    listener = host.socket_listeners[wildcard_key(address)]
  end
  if not listener or listener.closed then
    return nil, 'ECONNREFUSED', 'connection refused'
  end
  local client, server = pair(host, 'socket')
  raw.rx, raw.tx = client.rx, client.tx
  raw.rx.reader, raw.tx.writer = raw, raw
  raw.address = raw.address
    or {
      kind = address.kind == 'inet6' and 'inet6' or 'inet4',
      family = address.kind == 'inet6' and 'inet6' or 'inet4',
      host = address.kind == 'inet6' and '::1' or '127.0.0.1',
      port = host.next_ephemeral_port,
    }
  host.next_ephemeral_port = host.next_ephemeral_port + 1
  raw.peer = copy(listener.address)
  server.address, server.peer = copy(listener.address), copy(raw.address)
  listener.pending[#listener.pending + 1] = { raw = server, peer = raw.address }
  if listener.handle then
    listener.handle:mark_readable()
  end
  update(raw.rx)
  update(raw.tx)
  return true
end

function Binding.net.socket_error()
  return 0
end
function Binding.net.query(raw, peer)
  return copy(peer and raw.peer or raw.address)
end
function Binding.net.prime(handle)
  local raw = handle._handle
  if raw.rx then
    update(raw.rx)
  end
  if raw.tx then
    update(raw.tx)
  end
end

function Binding.net.receive(raw, maximum)
  if raw.closed then
    return nil, nil, nil, CLOSED
  end
  local packet = table.remove(raw.incoming, 1)
  if not packet then
    if raw.handle then
      raw.handle:clear_readable()
    end
    return nil, nil, nil, AGAIN
  end
  if #raw.incoming == 0 and raw.handle then
    raw.handle:clear_readable()
  end
  maximum = math.max(0, math.floor(tonumber(maximum) or 65535))
  local data, flags = packet.data, {}
  if #data > maximum then
    flags.truncated, flags.original_size = true, #data
    data = data:sub(1, maximum)
  end
  return data, copy(packet.peer), flags
end

function Binding.net.send(raw, data, destination)
  if raw.closed then
    return nil, CLOSED
  end
  local target = raw.host.datagram_sockets[address_key(destination)]
    or raw.host.datagram_sockets[wildcard_key(destination)]
  if type(raw.host.datagram_send) == 'function' then
    local result, err = raw.host.datagram_send(raw.host, raw.handle, data, destination)
    if result == nil and err ~= nil then
      return nil, err
    end
    if result == false then
      return #data
    end
  end
  if target and not target.closed then
    target.incoming[#target.incoming + 1] = { data = data, peer = copy(raw.address) }
    if target.handle then
      target.handle:mark_readable()
    end
  end
  if raw.handle then
    raw.handle:mark_writable()
  end
  return #data
end

Binding.resolver = {
  query = function(host, endpoint, opts)
    local records, value = {}, host.resolver_records[endpoint.host]
    local family = (opts or {}).family or endpoint.family_hint
    local function add(address)
      if family == nil or family == 'unspec' or address.kind == family or address.family == family then
        local item = copy(address)
        item.port = item.port or tonumber(endpoint.service) or endpoint.service
        records[#records + 1] = item
      end
    end
    if type(value) == 'table' then
      if value.kind or value.family then
        add(value)
      else
        for i = 1, #value do
          add(value[i])
        end
      end
    elseif endpoint.host == 'localhost' then
      add({ kind = 'inet4', family = 'inet4', host = '127.0.0.1' })
      add({ kind = 'inet6', family = 'inet6', host = '::1' })
    elseif type(endpoint.host) == 'string' and endpoint.host:match('^%d+%.%d+%.%d+%.%d+$') then
      add({ kind = 'inet4', family = 'inet4', host = endpoint.host })
    elseif type(endpoint.host) == 'string' and endpoint.host:find(':', 1, true) then
      add({ kind = 'inet6', family = 'inet6', host = endpoint.host })
    end
    if #records == 0 then
      return nil, 'EAI_NONAME', 'name or service not known'
    end
    return records
  end,
  address = function(record)
    return record
  end,
}

local function manual_process(Fd)
  local ProcessCore = require('fibers.io.process').core
  local signals = ProcessCore.signals()
  local Class = {}
  Class.__index = Class

  function Class:bind_runtime(runtime)
    self.runtime = runtime
    IOAudit.bind(self, runtime)
    for _, handle in pairs(self.child_endpoints or {}) do
      if handle then handle:bind_runtime(runtime) end
    end
    return self
  end

  function Class:pid() return self._pid end
  function Class:open_exit_op() return Op.always(self) end
  function Class:exit_op() return self.exit_completion:result_op() end

  function Class:signal(value, target)
    if self.reaped then
      return nil, HostError.closed('process', 'signal', { pid = self._pid })
    end
    local number, err = signals.normalise(value)
    if not number then return nil, err end
    self.signals[#self.signals + 1] = { signal = number, target = target }
    if self.on_signal then return self.on_signal(self, number, target) end
    if number == signals.numbers.kill or number == signals.numbers.term then
      self:complete(ProcessCore.signalled(signals, number))
    end
    return true
  end

  function Class:close(reason)
    if self.closed then return true end
    self.closed = true
    IOAudit.closing(self, reason)
    for _, handle in pairs(self.child_endpoints or {}) do
      if handle then handle:close(reason) end
    end
    self.host.processes[self._pid] = nil
    IOAudit.closed(self, true, nil, reason)
    return true
  end


  function Class:complete_op(status)
    status = status or ProcessCore.exited(0)
    return self.exit_completion:publish_success_op(status):wrap(function(ok, err)
      if not ok then
        return nil, err
      end
      self.status, self.reaped = status, true
      for _, handle in pairs(self.child_endpoints or {}) do
        if handle then
          handle:close('manual process exit')
        end
      end
      return true
    end)
  end
  function Class:complete(status)
    return perform(self:complete_op(status))
  end
  function Class:start()
    if self.started then
      return true
    end
    self.started = true
    if self.on_start then
      local ok, err = Protected.pcall(self.on_start, self, self.child_endpoints, self.spec)
      if not ok then
        self:complete(ProcessCore.exited(127))
        return nil, HostError.protocol('process', 'manual_start', tostring(err), { pid = self._pid })
      end
    end
    return true
  end

  return {
    is_supported = function()
      return true
    end,
    start_process = function(host, spec)
      local pid, child, endpoints = host.next_pid, {}, {}
      host.next_pid = pid + 1
      local label = spec.label or ('simulated-process-' .. tostring(pid))
      if spec.stdin == 'pipe' then
        child.stdin, endpoints.stdin = Fd.pipe({ host = host, label = label .. ':stdin' })
      end
      if spec.stdout == 'pipe' then
        endpoints.stdout, child.stdout = Fd.pipe({ host = host, label = label .. ':stdout' })
      end
      if spec.stderr == 'pipe' then
        endpoints.stderr, child.stderr = Fd.pipe({ host = host, label = label .. ':stderr' })
      elseif spec.stderr == 'stdout' then
        child.stderr = child.stdout
      end
      local process = Label.attach(setmetatable({
        _fibers_id = 'simulated-process-' .. tostring(pid),
        _pid = pid,
        spec = spec,
        host = host,
        exit_completion = Completion.new():label(label .. ':exit'),
        child_endpoints = child,
        signals = {},
        reaped = false,
        started = false,
        on_start = spec.on_start or host.on_process_start,
        on_signal = spec.on_signal or host.on_process_signal,
      }, Class), spec.label)
      IOAudit.created(process, { kind = 'process_handle' })
      host.processes[pid] = process
      return process, endpoints
    end,
  }
end
Binding.process = manual_process

Binding.features = { datagram_truncation = true }
Binding.time = {
  now = function() return 0 end,
  sleep = function() return true end,
}
Binding.poll = {
  wait = function() return nil, 'simulated-poll-unused' end,
}

local Posix = require('fibers.io.posix')
local Simulated = Posix.define(Binding)
local base_new = Simulated.new

function Simulated.new(opts)
  opts = opts or {}
  local host = base_new()
  local base_create_pipe = host.create_pipe
  local base_create_listener = host.create_listener
  local base_start_dial = host.start_dial
  local base_create_datagram = host.create_datagram
  local base_resolve = host.resolve
  local base_start_process = host.start_process

  host._now = opts.now or 0
  host._manual_serial = 0
  host.auto_advance_time = opts.auto_advance_time ~= false
  host.ready = {}
  host.socket_listeners = {}
  host.datagram_sockets = {}
  host.processes = {}
  host.next_ephemeral_port = opts.first_ephemeral_port or 40000
  host.next_pid = opts.first_pid or 1000
  host.resolver_records = opts.resolver_records or opts.dns or {}
  host.datagram_send = opts.datagram_send
  host.on_process_start = opts.on_process_start
  host.on_process_signal = opts.on_process_signal
  host.pipe_factory = opts.pipe_factory
  host.listener_factory = opts.listener_factory
  host.dial_factory = opts.dial_factory
  host.process_factory = opts.process_factory
  host.now = function() return host._now end

  local pipes = opts.pipes == true or host.pipe_factory ~= nil
  local sockets = opts.sockets == true
  local datagrams = opts.datagrams == true or opts.udp == true
  local processes = opts.processes == true or opts.exec == true or host.process_factory ~= nil
  local resolver = opts.resolver ~= false

  local features = { time = true, readiness = true, file = true, file_backend = 'memory' }
  host._features = features
  if pipes then features.pipe = true end
  if sockets then
    features.socket = true
    features.socket_ipv4 = true
    features.socket_ipv6 = true
    features.socket_unix = true
  end
  if datagrams then
    features.datagram = true
    features.datagram_truncation = true
  end
  if resolver then features.resolver = true end
  if processes then features.process = true end

  host.file_storage = require('tests.support.memory_file_provider').new({
    files = opts.files,
    directories = opts.directories,
  })

  function host:sleep(seconds)
    self._now = self._now + math.max(0, tonumber(seconds) or 0)
    return true
  end

  function host:set_time(value)
    self._now = tonumber(value) or self._now
    return self._now
  end

  function host:advance(value)
    self._now = self._now + (tonumber(value) or 0)
    return self._now
  end

  function host:set_readiness(key, mode, value)
    mode = WaitSet.normalise_mode(mode)
    local record = self.ready[tostring(key)] or {}
    self.ready[tostring(key)] = record
    record[mode] = value == nil and true or value or nil
    return true
  end

  function host:readable(key) return self:set_readiness(key, 'read', true) end
  function host:writable(key) return self:set_readiness(key, 'write', true) end

  function host:clear_readiness(key, mode)
    local record = self.ready[tostring(key)]
    if not record then return true end
    if mode == nil then
      self.ready[tostring(key)] = nil
    else
      record[WaitSet.normalise_mode(mode)] = nil
    end
    return true
  end

  function host:is_ready(key, mode)
    local record = self.ready[tostring(key)]
    return not not (record and record[WaitSet.normalise_mode(mode)])
  end

  function host:complete_process(pid_or_process, status)
    local process = type(pid_or_process) == 'table' and pid_or_process or self.processes[pid_or_process]
    if not process then
      return nil, HostError.invalid_argument('process', 'complete', { pid = pid_or_process })
    end
    return process:complete(status)
  end

  function host:deliver_datagram(address, data, peer, fields)
    local raw = self.datagram_sockets[address_key(address)] or self.datagram_sockets[wildcard_key(address)]
    if not raw or raw.closed then
      return nil, HostError.closed('datagram', 'deliver', { address = address })
    end
    raw.incoming[#raw.incoming + 1] = {
      data = assert(data, 'datagram data required'),
      peer = Address.validate(peer or Address.ipv4('127.0.0.1', 53)),
      fields = fields,
    }
    if raw.handle then raw.handle:mark_readable() end
    return true
  end

  host.create_pipe = pipes and function(self, options)
    if self.pipe_factory then return self.pipe_factory(self, options or {}) end
    return base_create_pipe(self, options)
  end or false

  host.create_listener = sockets and function(self, address, options)
    if self.listener_factory then return self.listener_factory(self, address, options or {}) end
    return base_create_listener(self, address, options)
  end or false

  host._manual_dial_socket = sockets and function(self, address, options)
    local handle, err = base_start_dial(self, address, options)
    if not handle then return nil, nil, err end
    local connected, peer, finish_err = handle:finish_connect()
    if not connected then
      handle:close(finish_err or 'manual dial did not complete')
      return nil, nil, finish_err
    end
    return connected, peer
  end or false

  host.start_dial = sockets and function(self, address, options)
    if self.dial_factory then return self.dial_factory(self, address, options or {}) end
    return base_start_dial(self, address, options)
  end or false

  host.create_datagram = datagrams and function(self, address, options)
    return base_create_datagram(self, address, options)
  end or false

  host.resolve = resolver and function(self, endpoint, options)
    return base_resolve(self, endpoint, options)
  end or false

  -- A deterministic host policy for Happy Eyeballs tests.  Production hosts may
  -- use routing and source-address information; the simulated host declares its
  -- simpler IPv6-then-IPv4 policy explicitly rather than relying on a
  -- coordinator-side guess.
  function host:sort_destination_addresses(addresses)
    local ranked = {}
    for i = 1, #addresses do
      ranked[i] = { address = addresses[i], index = i }
    end
    table.sort(ranked, function(left, right)
      local lf = left.address.kind == 'inet6' and 0 or 1
      local rf = right.address.kind == 'inet6' and 0 or 1
      if lf ~= rf then return lf < rf end
      return left.index < right.index
    end)
    local out = {}
    for i = 1, #ranked do out[i] = ranked[i].address end
    return out
  end
  features.happy_eyeballs_destination_ordering = 'simulated'

  host.start_process = processes and function(self, spec)
    if self.process_factory then return self.process_factory(self, spec) end
    return base_start_process(self, spec)
  end or false

  function host:file_provider()
    return self.file_storage
  end

  function host:block(runtime, waits, _status, options)
    if self._closed then error('simulated host is closed', 2) end
    local set, delivered = WaitSet.build(waits), false
    for i = 1, #set.records do
      local record = set.records[i]
      delivered = WaitSet.deliver(
        record,
        self:is_ready(record.key, 'read'),
        self:is_ready(record.key, 'write')
      ) or delivered
    end
    if delivered then return true, 'readiness' end
    if set.deadline ~= nil then
      if self.auto_advance_time and (options or {}).auto_advance_time ~= false then
        if self._now < set.deadline then self._now = set.deadline end
        return true, 'time'
      end
      return nil, 'time-not-ready'
    end
    return nil, #set.records > 0 and 'readiness-not-ready' or 'unsupported-waits'
  end

  return host
end

return Simulated
