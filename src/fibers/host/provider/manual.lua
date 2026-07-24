-- Deterministic in-memory provider for the shared host implementation.

local Completion = require('fibers.resource.completion')
local HostError = require('fibers.host.error')
local IOAudit = require('fibers.diagnostics.io')
local perform = require('fibers.perform')
local Protected = require('fibers.internal.protected')
local WaitSet = require('fibers.host.wait_set')

local Provider = {
  name = 'manual',
  family = 'manual',
  capabilities = { datagram_truncation = true },
}

local AGAIN, CLOSED, BROKEN = 'again', 'closed', 'broken_pipe'
Provider.errors = {
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
  if type(address) ~= 'table' then
    return tostring(address)
  end
  if address.kind == 'unix' or address.family == 'unix' then
    return 'unix:' .. tostring(address.path)
  end
  local family = address.kind or address.family or 'inet4'
  if family == 'inet' then
    family = tostring(address.host or ''):find(':', 1, true) and 'inet6' or 'inet4'
  end
  return table.concat({ family, tostring(address.host or '0.0.0.0'), tostring(address.port or 0) }, ':')
end

local function wildcard_key(address)
  local family = address.kind == 'inet6' or address.family == 'inet6' and 'inet6' or 'inet4'
  return address_key({ kind = family, host = family == 'inet6' and '::' or '0.0.0.0', port = address.port })
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
    key = 'manual-' .. kind .. '-' .. tostring(host._manual_serial),
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

Provider.fd = {
  supported = function()
    return true
  end,
  validate = function(value)
    return assert(value, 'manual descriptor required')
  end,
  key = function(value)
    return value.key
  end,
  decorate = function(handle, value)
    value.handle = handle
    update(value.rx or value.tx or {})
  end,
  pipe = function(host)
    return pipe_pair(assert(host, 'manual pipe requires host'))
  end,
  set_nonblocking = function()
    return true
  end,
  set_cloexec = function()
    return true
  end,
}

function Provider.fd.read(raw, maximum)
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

function Provider.fd.write(raw, bytes)
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

function Provider.fd.shutdown(raw, mode)
  if mode == 'read' and raw.rx then
    raw.rx.read_closed, raw.rx.chunks, raw.rx.bytes = true, {}, 0
    update(raw.rx)
  elseif mode == 'write' and raw.tx then
    raw.tx.write_closed = true
    update(raw.tx)
  end
  return true
end

function Provider.fd.close(raw)
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

Provider.net = {
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
    local family = address.kind or address.family
    if family == 'inet' then
      family = tostring(address.host or ''):find(':', 1, true) and 'inet6' or 'inet4'
    end
    family = family or 'inet4'
    return { family = family, native = copy(address) }
  end,
  decode = function(address)
    return address and copy(address) or nil
  end,
  open = function(family, kind, host)
    local raw =
      endpoint(assert(host, 'manual socket requires host'), kind, kind == 'stream', kind == 'stream')
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

function Provider.net.bind(raw, address)
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

function Provider.net.listen(raw)
  raw.pending = {}
  raw.listener_key = raw.bound_key
  raw.host.socket_listeners[raw.listener_key] = raw
  return true
end

function Provider.net.accept(raw)
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

function Provider.net.connect(raw, address)
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

function Provider.net.socket_error()
  return 0
end
function Provider.net.query(raw, peer)
  return copy(peer and raw.peer or raw.address)
end
function Provider.net.prime(handle)
  local raw = handle.handle
  if raw.rx then
    update(raw.rx)
  end
  if raw.tx then
    update(raw.tx)
  end
end

function Provider.net.receive(raw, maximum)
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

function Provider.net.send(raw, data, destination)
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

Provider.resolver = {
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

local function manual_process(Fd, ProcessCore)
  local signals = ProcessCore.signals()
  local Class = ProcessCore.class({
    signals = signals,
    bind = function(self, runtime)
      for _, handle in pairs(self.child_endpoints or {}) do
        if handle then
          handle:bind_runtime(runtime)
        end
      end
    end,
    wait = function(self)
      return self.exit_completion:terminal_op()
    end,
    reap = function(self)
      local terminal = self.exit_completion:state_value()
      if terminal.kind ~= 'succeeded' then
        return nil, HostError.would_block('process', 'reap', { pid = self._pid })
      end
      if not self.reaped then
        self.status, self.reaped = terminal.values and terminal.values[1] or terminal.value, true
      end
      return self.status
    end,
    signal = function(self, number, target)
      self.signals[#self.signals + 1] = { signal = number, target = target }
      if self.on_signal then
        return self.on_signal(self, number, target)
      end
      if number == signals.numbers.kill or number == signals.numbers.term then
        self:complete(ProcessCore.signalled(signals, number))
      end
      return true
    end,
    close = function(self, reason)
      for _, handle in pairs(self.child_endpoints or {}) do
        if handle then
          handle:close(reason)
        end
      end
      self.host.processes[self._pid] = nil
      return true
    end,
  })

  function Class:complete_op(status)
    return self.exit_completion:publish_success_op(status or ProcessCore.exited(0)):wrap(function(ok, err)
      if not ok then
        return nil, err
      end
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
      local name = spec.name or ('manual-process-' .. tostring(pid))
      if spec.stdin == 'pipe' then
        child.stdin, endpoints.stdin = Fd.pipe({ host = host, name = name .. ':stdin' })
      end
      if spec.stdout == 'pipe' then
        endpoints.stdout, child.stdout = Fd.pipe({ host = host, name = name .. ':stdout' })
      end
      if spec.stderr == 'pipe' then
        endpoints.stderr, child.stderr = Fd.pipe({ host = host, name = name .. ':stderr' })
      elseif spec.stderr == 'stdout' then
        child.stderr = child.stdout
      end
      local process = setmetatable({
        name = name,
        _pid = pid,
        spec = spec,
        host = host,
        exit_completion = Completion.new(name .. ':exit'),
        child_endpoints = child,
        signals = {},
        reaped = false,
        started = false,
        on_start = spec.on_start or host.on_process_start,
        on_signal = spec.on_signal or host.on_process_signal,
      }, Class)
      IOAudit.created(process, { kind = 'process_handle' })
      host.processes[pid] = process
      return process, endpoints
    end,
  }
end
Provider.process = manual_process

Provider.time = {
  now = function()
    return 0
  end,
  sleep = function()
    return true
  end,
}
Provider.poll = {
  wait = function()
    return {}
  end,
}

Provider.create = function(opts)
  local state = {
    _now = opts.now or 0,
    _manual_serial = 0,
    auto_advance_time = opts.auto_advance_time ~= false,
    ready = {},
    socket_listeners = {},
    datagram_sockets = {},
    processes = {},
    next_ephemeral_port = opts.first_ephemeral_port or 40000,
    next_pid = opts.first_pid or 1000,
    resolver_records = opts.resolver_records or opts.dns or {},
    datagram_send = opts.datagram_send,
    on_process_start = opts.on_process_start,
    on_process_signal = opts.on_process_signal,
    enable_pipes = opts.pipes == true,
    enable_sockets = opts.sockets == true,
    enable_datagrams = opts.datagrams == true or opts.udp == true,
    enable_processes = opts.processes == true or opts.exec == true or opts.process_factory ~= nil,
    enable_resolver = opts.resolver ~= false,
  }
  state.now = function()
    return state._now
  end
  state.file_storage =
    require('fibers.file.memory_provider').new({ files = opts.files, directories = opts.directories })
  state.pipe_factory = opts.pipe_factory
  state.listener_factory = opts.listener_factory
  state.dial_factory = opts.dial_factory
  state.process_factory = opts.process_factory
  return state
end

Provider.file_provider = function(host)
  return host.file_storage
end
Provider.capability_builder = function(host)
  return {
    time = true,
    readiness = true,
    fd = false,
    pipe = host.enable_pipes or host.pipe_factory ~= nil,
    socket = host.enable_sockets,
    socket_ipv4 = host.enable_sockets,
    socket_ipv6 = host.enable_sockets,
    socket_unix = host.enable_sockets,
    datagram = host.enable_datagrams,
    datagram_truncation = host.enable_datagrams,
    resolver = host.enable_resolver,
    resolver_blocking = false,
    process = host.enable_processes or host.process_factory ~= nil,
    file = true,
    file_backend = 'memory',
    file_io_uring = false,
    file_aio_detected = false,
  }
end
Provider.methods = {}

function Provider.methods:set_time(value)
  self._now = tonumber(value) or self._now
  return self._now
end
function Provider.methods:advance(value)
  self._now = self._now + (tonumber(value) or 0)
  return self._now
end
function Provider.methods:set_readiness(key, mode, value)
  mode = WaitSet.normalise_mode(mode)
  local record = self.ready[tostring(key)] or {}
  self.ready[tostring(key)] = record
  record[mode] = value == nil and true or value or nil
  return true
end
function Provider.methods:readable(key)
  return self:set_readiness(key, 'read', true)
end
function Provider.methods:writable(key)
  return self:set_readiness(key, 'write', true)
end
function Provider.methods:clear_readiness(key, mode)
  local record = self.ready[tostring(key)]
  if not record then
    return true
  end
  if mode == nil then
    self.ready[tostring(key)] = nil
  else
    record[WaitSet.normalise_mode(mode)] = nil
  end
  return true
end
function Provider.methods:is_ready(key, mode)
  local record = self.ready[tostring(key)]
  return not not (record and record[WaitSet.normalise_mode(mode)])
end
function Provider.methods:complete_process(pid_or_process, status)
  local process = type(pid_or_process) == 'table' and pid_or_process or self.processes[pid_or_process]
  if not process then
    return nil, HostError.invalid_argument('process', 'complete', { pid = pid_or_process })
  end
  return process:complete(status)
end
function Provider.methods:deliver_datagram(address, data, peer, fields)
  local raw = self.datagram_sockets[address_key(address)] or self.datagram_sockets[wildcard_key(address)]
  if not raw or raw.closed then
    return nil, HostError.closed('datagram', 'deliver', { address = address })
  end
  raw.incoming[#raw.incoming + 1] = {
    data = assert(data, 'datagram data required'),
    peer = copy(peer or { kind = 'inet4', host = '127.0.0.1', port = 53 }),
    fields = fields,
  }
  if raw.handle then
    raw.handle:mark_readable()
  end
  return true
end

Provider.methods_factory = function(parts)
  local Fd, Socket, Process = parts.fd, parts.socket, parts.process
  return {
    create_pipe = function(self, opts)
      if self.pipe_factory then
        return self.pipe_factory(self, opts or {})
      end
      if not self.capabilities.pipe then
        return nil, nil, HostError.unsupported('host', 'pipe', { host = self.name })
      end
      return Fd.pipe({
        host = self,
        name = opts and opts.name,
        nonblocking = opts == nil or opts.nonblocking ~= false,
      })
    end,
    create_listener = function(self, address, opts)
      if self.listener_factory then
        return self.listener_factory(self, address, opts or {})
      end
      if not self.capabilities.socket then
        return nil, HostError.unsupported('host', 'listen', { host = self.name, address = address })
      end
      return Socket.create_listener(self, address, opts)
    end,
    dial_socket = function(self, address, opts)
      local handle, err = Socket.start_dial(self, address, opts)
      if not handle then
        return nil, nil, err
      end
      local connected, peer, finish_err = handle:finish_connect()
      if not connected then
        handle:close(finish_err or 'manual dial did not complete')
        return nil, nil, finish_err
      end
      return connected, peer
    end,
    start_dial = function(self, address, opts)
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
    end,
    start_process = function(self, spec)
      if self.process_factory then
        return self.process_factory(self, spec)
      end
      if not self.capabilities.process or not Process then
        return nil, nil, HostError.unsupported('host', 'process', { host = self.name })
      end
      return Process.start_process(self, spec)
    end,
  }
end

Provider.block = function(host, runtime, waits, status, opts)
  local set, delivered = WaitSet.build(waits), false
  for i = 1, #set.records do
    local record = set.records[i]
    if
      WaitSet.deliver(runtime, record, host:is_ready(record.key, 'read'), host:is_ready(record.key, 'write'))
    then
      delivered = true
    end
  end
  if delivered then
    if host.on_wake then
      host.on_wake('readiness', waits, status)
    end
    return true, 'readiness'
  end
  if set.deadline ~= nil then
    if host.auto_advance_time and (opts or {}).auto_advance_time ~= false then
      if host._now < set.deadline then
        if host.on_wait then
          host.on_wait(set.deadline, set.deadline - host._now, waits, status)
        end
        host._now = set.deadline
      end
      if host.on_wake then
        host.on_wake('time', waits, status)
      end
      return true, 'time'
    end
    return nil, 'time-not-ready'
  end
  if host.on_unsupported then
    host.on_unsupported(waits, status)
  end
  return #set.records > 0 and nil or nil, #set.records > 0 and 'readiness-not-ready' or 'unsupported-waits'
end

return Provider
