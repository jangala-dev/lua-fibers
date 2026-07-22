-- Shared lifecycle and policy for narrow native host adapters.

local HostError = require('fibers.host.error')
local WaitSet = require('fibers.host.wait_set')

local Adapter = {}

-- Host families ---------------------------------------------------------

function Adapter.unsupported(prefix, reason, methods)
  local value = {
    is_supported = function()
      return false, reason
    end,
    support_reason = function()
      return reason
    end,
  }
  for _, name in ipairs(methods or { 'new' }) do
    value[name] = function()
      error(prefix .. ': ' .. tostring(reason), 2)
    end
  end
  return value
end

local function supported(module)
  return module and (type(module.is_supported) ~= 'function' or module.is_supported())
end
local function capability(module, name)
  if not supported(module) then
    return false
  end
  return not name or type(module[name]) ~= 'function' or not not module[name]()
end

local function default_capabilities(spec)
  local socket, datagram = capability(spec.socket), capability(spec.datagram)
  local resolver, process, fd = capability(spec.resolver), capability(spec.process), capability(spec.fd)
  local out = {
    time = true,
    readiness = true,
    fd = fd,
    pipe = fd,
    socket = socket,
    socket_ipv4 = socket and capability(spec.socket, 'supports_ipv4'),
    socket_ipv6 = socket and capability(spec.socket, 'supports_ipv6'),
    socket_unix = socket and capability(spec.socket, 'supports_unix'),
    datagram = datagram,
    datagram_truncation = spec.datagram_truncation == true,
    resolver = resolver,
    resolver_blocking = resolver,
    process = process,
    file = process,
    file_backend = process and 'worker' or nil,
    file_io_uring = false,
    file_aio_detected = false,
  }
  for key, value in pairs(spec.capabilities or {}) do
    out[key] = value
  end
  return out
end

function Adapter.define(spec)
  local Module, HostClass = {}, {}
  HostClass.__index = HostClass

  function Module.is_supported()
    local ok = spec.is_supported()
    return not not ok
  end
  function Module.support_reason()
    if Module.is_supported() then
      return nil
    end
    return spec.support_reason and spec.support_reason()
      or ('required ' .. spec.name .. ' functions unavailable')
  end

  function Module.new(opts)
    opts = opts or {}
    if not Module.is_supported() then
      error(spec.prefix .. ': ' .. tostring(Module.support_reason()), 2)
    end
    local state = spec.create and spec.create(opts) or {}
    state.kind, state.name, state.family = spec.name, spec.name, spec.family
    state.fd = spec.fd
    state.capabilities = spec.capability_builder and spec.capability_builder(state, opts)
      or default_capabilities(spec)
    state.on_wait, state.on_wake, state.on_unsupported = opts.on_wait, opts.on_wake, opts.on_unsupported
    state.now = state.now or function()
      return spec.now()
    end
    return setmetatable(state, HostClass)
  end

  function HostClass:create_pipe(opts)
    if not self.capabilities.pipe then
      return nil, nil, HostError.unsupported('host', 'pipe', { host = self.name })
    end
    return spec.fd.pipe({
      host = self,
      name = opts and opts.name,
      nonblocking = opts == nil or opts.nonblocking ~= false,
    })
  end
  function HostClass:create_listener(address, opts)
    if not self.capabilities.socket then
      return nil, HostError.unsupported('host', 'listen', { host = self.name, address = address })
    end
    return spec.socket.create_listener(self, address, opts)
  end
  function HostClass:start_dial(address, opts)
    if not self.capabilities.socket then
      return nil, HostError.unsupported('host', 'dial', { host = self.name, address = address })
    end
    return spec.socket.start_dial(self, address, opts)
  end
  function HostClass:create_datagram(address, opts)
    if not self.capabilities.datagram then
      return nil, HostError.unsupported('host', 'datagram', { host = self.name, address = address })
    end
    return spec.datagram.create_datagram(self, address, opts)
  end
  function HostClass:resolve(endpoint, opts)
    if not supported(spec.resolver) then
      return nil, HostError.unsupported('host', 'resolve', { endpoint = endpoint })
    end
    return spec.resolver.resolve(self, endpoint, opts)
  end
  function HostClass:start_process(process_spec)
    if not self.capabilities.process or not supported(spec.process) then
      return nil, nil, HostError.unsupported('host', 'process', { host = self.name })
    end
    return spec.process.start_process(self, process_spec)
  end
  function HostClass:file_provider(runtime, opts)
    if spec.file_provider then
      return spec.file_provider(self, runtime, opts)
    end
    if self.capabilities.process then
      return require('fibers.file.worker_provider').new(runtime, opts)
    end
  end
  function HostClass:sleep(seconds)
    return spec.sleep(seconds)
  end
  function HostClass:block(rt, waits, status, opts)
    if self.closed then
      error(spec.prefix .. ': host is closed', 2)
    end
    return spec.block(self, rt, waits, status, opts)
  end
  function HostClass:close()
    if self.closed then
      return true
    end
    self.closed = true
    if spec.close then
      return spec.close(self)
    end
    return true
  end

  for name, method in pairs(spec.methods or {}) do
    HostClass[name] = method
  end
  Module.Class = HostClass
  return Module
end

function Adapter.polling(spec)
  spec.block = function(self, rt, waits, status)
    waits = waits or {}
    local plan = WaitSet.build(waits, spec.poll_keys)
    if plan.unsupported then
      if self.on_unsupported then
        self.on_unsupported(waits, status)
      end
      return nil, 'unsupported-readiness-key'
    end
    if #plan.records == 0 then
      return WaitSet.block_without_io(self, rt, plan, status)
    end
    local ready, reason = spec.poll(plan, WaitSet.timeout_ms(rt, plan))
    if not ready then
      return true, reason or 'poll-interrupted'
    end
    local delivered = false
    for i = 1, #ready do
      local item = ready[i]
      if WaitSet.deliver(rt, item.record, item.read, item.write) then
        delivered = true
      end
    end
    if delivered then
      return true, 'readiness'
    end
    if plan.deadline ~= nil and rt:now() >= plan.deadline then
      return true, 'time'
    end
    return true, 'poll'
  end
  return Adapter.define(spec)
end

-- Stream sockets --------------------------------------------------------

local function close_failed(handle, err)
  if handle then
    handle:close(err)
  end
  return nil, err
end

function Adapter.socket(spec)
  local Socket = {}
  local function raw_of(handle)
    return spec.raw and spec.raw(handle) or handle.handle or handle.fd or handle.obj
  end

  local function unsupported(reason)
    local value = Adapter.unsupported(spec.prefix, reason, { 'create_listener', 'start_dial' })
    value.supports_ipv4 = function()
      return false
    end
    value.supports_ipv6 = function()
      return false
    end
    value.supports_unix = function()
      return false
    end
    return value
  end

  if spec.unavailable then
    return unsupported(spec.unavailable)
  end

  function Socket.supports_ipv4()
    return spec.supports('inet4')
  end
  function Socket.supports_ipv6()
    return spec.supports('inet6')
  end
  function Socket.supports_unix()
    return spec.supports('unix')
  end
  function Socket.is_supported()
    return Socket.supports_ipv4() or Socket.supports_ipv6() or Socket.supports_unix()
  end
  function Socket.support_reason()
    return Socket.is_supported() and nil or spec.support_reason
  end

  local function wrap(raw, host, name, family)
    local handle, err = spec.wrap(raw, host, name)
    if not handle then
      return nil, HostError.normalise(err, { domain = 'socket', action = 'wrap' })
    end
    handle.family = spec.handle_family
    handle.socket_family = family
    handle.local_address = function(self)
      return spec.query(raw_of(self), false, family)
    end
    handle.peer_address_value = function(self)
      return spec.query(raw_of(self), true, family)
    end
    return handle
  end

  function Socket.create_listener(host, address, opts)
    opts = opts or {}
    local endpoint, address_err = spec.encode(address)
    if not endpoint then
      return nil, address_err
    end
    if not spec.supports(endpoint.family) then
      return nil, HostError.unsupported('socket', 'listen', { address = address })
    end

    local raw, open_err = spec.open(host, endpoint.family)
    if not raw then
      return nil, open_err
    end
    local handle, wrap_err = wrap(raw, host, opts.name or (spec.name .. '-listener'), endpoint.family)
    if not handle then
      spec.close_raw(raw)
      return nil, wrap_err
    end

    if not spec.is_unix(endpoint.family) and opts.reuse_address ~= false then
      local ok, err = spec.set_reuse(raw, true, address)
      if not ok then
        return close_failed(handle, err)
      end
    elseif spec.is_unix(endpoint.family) and opts.unlink_existing == true then
      spec.unlink(address.path)
    end

    local ok, err = spec.bind(raw, endpoint, address)
    if not ok then
      return close_failed(handle, err)
    end
    ok, err = spec.listen(raw, tonumber(opts.backlog) or 128, address)
    if not ok then
      return close_failed(handle, err)
    end

    local unix_path = spec.is_unix(endpoint.family) and address.path or nil
    if unix_path and opts.unlink_on_close ~= false then
      handle._after_close = function()
        spec.unlink(unix_path)
      end
    end
    handle.address = spec.query(raw, false, endpoint.family) or address
    handle.local_address = function(self)
      return self.address
    end
    handle.accept = function(self)
      self:clear_readable()
      local child_raw, peer, accept_err = spec.accept(raw_of(self), self.address)
      if not child_raw then
        return nil, nil, accept_err
      end
      local child, child_err =
        wrap(child_raw, host, (opts.name or 'listener') .. ':accepted', endpoint.family)
      if not child then
        spec.close_raw(child_raw)
        return nil, nil, child_err
      end
      if not spec.is_unix(endpoint.family) and opts.nodelay ~= false then
        local set, nodelay_err = spec.set_nodelay(child_raw, true, self.address)
        if not set then
          child:close(nodelay_err)
          return nil, nil, nodelay_err
        end
      end
      peer = spec.decode_peer(peer, endpoint.family) or spec.query(child_raw, true, endpoint.family)
      child.peer_address = peer
      child.local_address_value = spec.query(child_raw, false, endpoint.family)
      if spec.prime then
        spec.prime(child)
      end
      return child, peer
    end
    return handle
  end

  function Socket.start_dial(host, address, opts)
    opts = opts or {}
    local endpoint, address_err = spec.encode(address)
    if not endpoint then
      return nil, address_err
    end
    if not spec.supports(endpoint.family) then
      return nil, HostError.unsupported('socket', 'dial', { address = address })
    end

    local raw, open_err = spec.open(host, endpoint.family)
    if not raw then
      return nil, open_err
    end
    local handle, wrap_err = wrap(raw, host, opts.name or (spec.name .. '-dial'), endpoint.family)
    if not handle then
      spec.close_raw(raw)
      return nil, wrap_err
    end

    if opts.local_address then
      local local_endpoint, local_err = spec.encode(opts.local_address)
      if not local_endpoint then
        return close_failed(handle, local_err)
      end
      if local_endpoint.family ~= endpoint.family then
        return close_failed(
          handle,
          HostError.invalid_argument('socket', 'bind', {
            address = opts.local_address,
            message = 'local and peer address families differ',
          })
        )
      end
      local bound, bind_err = spec.bind(raw, local_endpoint, opts.local_address)
      if not bound then
        return close_failed(handle, bind_err)
      end
    end

    if not spec.is_unix(endpoint.family) and opts.nodelay ~= false then
      local ok, err = spec.set_nodelay(raw, true, address)
      if not ok then
        return close_failed(handle, err)
      end
    end

    handle.target_address = address
    local state, connect_err = spec.connect(raw, endpoint, address)
    if not state then
      return close_failed(handle, connect_err)
    end
    handle._connect_complete = state == 'connected'
    handle._connect_pending = state == 'pending'
    if handle._connect_complete and spec.prime then
      spec.prime(handle)
    end

    handle.finish_connect = function(self)
      if self._connect_complete then
        return self, spec.query(raw_of(self), true, endpoint.family) or address
      end
      self:clear_writable()
      local next_state, err = spec.finish_connect(raw_of(self), endpoint, address)
      if next_state == 'pending' then
        return nil, nil, err
      end
      if not next_state then
        return nil, nil, err
      end
      self._connect_complete, self._connect_pending = true, false
      if spec.prime then
        spec.prime(self)
      end
      return self, spec.query(raw_of(self), true, endpoint.family) or address
    end
    return handle
  end

  return Socket
end

-- Datagram sockets ------------------------------------------------------

function Adapter.datagram(spec)
  if spec.unavailable then
    return Adapter.unsupported(spec.prefix, spec.unavailable, { 'create_datagram' })
  end

  local Provider = {}
  local function raw_of(handle)
    return spec.raw and spec.raw(handle) or handle.handle or handle.fd or handle.obj
  end
  function Provider.is_supported()
    return spec.is_supported()
  end

  function Provider.create_datagram(host, address, opts)
    opts = opts or {}
    if not Provider.is_supported() then
      return nil, HostError.unsupported('datagram', 'open', { reason = spec.support_reason })
    end
    local endpoint, address_err = spec.encode(address)
    if not endpoint then
      return nil, address_err
    end
    local raw, open_err = spec.open(host, endpoint.family, address)
    if not raw then
      return nil, open_err
    end

    local function fail(err)
      spec.close_raw(raw)
      return nil, err
    end
    if opts.reuse_address == true then
      local ok, err = spec.set_reuse(raw, true, address)
      if not ok then
        return fail(err)
      end
    end
    local ok, bind_err = spec.bind(raw, endpoint, address)
    if not ok then
      return fail(bind_err)
    end

    local handle, wrap_err = spec.wrap(raw, host, opts.name or (spec.name .. '-datagram'))
    if not handle then
      return fail(wrap_err)
    end
    handle.address = spec.query(raw, endpoint.family) or address
    handle.local_address = function(self)
      return self.address
    end
    handle.recv_from = function(self, max_size)
      self:clear_readable()
      return spec.receive(raw_of(self), max_size, endpoint.family, self.address)
    end
    handle.send_to = function(self, data, destination)
      self:clear_writable()
      local target, target_err = spec.encode(destination)
      if not target then
        return nil, target_err
      end
      if target.family ~= endpoint.family then
        return nil,
          HostError.protocol('datagram', 'send_to', 'source and destination address families differ', {
            source = self.address,
            destination = destination,
          })
      end
      return spec.send(raw_of(self), data, target, destination)
    end
    return handle
  end

  return Provider
end

-- Blocking resolvers ----------------------------------------------------

local function address_key(address)
  return table.concat({
    address.kind,
    tostring(address.host),
    tostring(address.port),
    tostring(address.scope_id or 0),
  }, ':')
end

function Adapter.resolver(spec)
  local Resolver = {}
  function Resolver.is_supported()
    return spec.is_supported()
  end
  function Resolver.support_reason()
    return Resolver.is_supported() and nil or spec.reason
  end
  function Resolver.resolve(_host, endpoint, opts)
    local records, err = spec.query(_host, endpoint, opts or {})
    if not records then
      return nil, err
    end
    local out, seen = {}, {}
    for _, record in spec.records(records) do
      local address = spec.address(record, endpoint.service)
      if address then
        local key = address_key(address)
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = address
        end
      end
    end
    if #out == 0 then
      return nil,
        HostError.system(
          'resolver',
          'resolve',
          'name resolved to no usable stream addresses',
          'EAI_NONAME',
          nil,
          { endpoint = endpoint }
        )
    end
    return out
  end
  return Resolver
end

return Adapter
