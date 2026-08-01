-- Final host construction over one raw binding table.
--
-- Bindings supply native calls and value conversion. This module constructs
-- Fibers handles, network policy, polling, processes and the final host object
-- directly; there is no adapter description between the binding and the host.

local FlowErrors = require('fibers.resource.flow.errors')
local Handle = require('fibers.io.handle')
local IOError = require('fibers.io.error')
local WaitSet = require('fibers.embed.wait_set')
local Address = require('fibers.net.address')

local Posix = {}

local function unavailable(prefix, reason)
  return {
    is_supported = function()
      return false, reason
    end,
    support_reason = function()
      return reason
    end,
    new = function()
      error(prefix .. ': ' .. tostring(reason), 2)
    end,
    platform = function()
      error(prefix .. ': ' .. tostring(reason), 2)
    end,
  }
end

local function error_detail(binding, errno, fallback)
  local errors = binding.errors or {}
  return fallback
      or (errors.message and errors.message(errno))
      or (errno and ('errno ' .. tostring(errno)) or 'native operation failed'),
    errors.name and errors.name(errno)
end

local function system_error(binding, domain, action, errno, message, fields)
  local detail, name = error_detail(binding, errno, message)
  return IOError.system(domain, action, detail, name, errno, fields)
end

local function is_error(binding, group, errno)
  local set = binding.errors and binding.errors[group]
  return type(set) == 'function' and set(errno) or type(set) == 'table' and set[errno] == true
end

local function make_fd(binding)
  local raw = assert(binding.fd, 'host binding requires fd operations')
  local Fd, generation = {}, 0
  local operations = {}

  function operations.read(self, maximum)
    maximum = tonumber(maximum) or 4096
    if maximum <= 0 then
      return ''
    end
    while true do
      local data, errno, message = raw.read(self.handle, maximum)
      if data ~= nil then
        if data == '' then
          return nil, FlowErrors.EOF
        end
        return data
      elseif is_error(binding, 'interrupted', errno) then
        -- Retry interrupted native calls.
      elseif is_error(binding, 'again', errno) then
        return nil, 'would_block', errno
      elseif is_error(binding, 'closed', errno) then
        return nil, 'closed', errno
      else
        return nil, error_detail(binding, errno, message), errno
      end
    end
  end

  function operations.write(self, bytes)
    if type(bytes) ~= 'string' then
      error('fd write expects bytes', 2)
    end
    if bytes == '' then
      return 0
    end
    while true do
      local count, errno, message = raw.write(self.handle, bytes)
      if count ~= nil then
        return count
      elseif is_error(binding, 'interrupted', errno) then
        -- Retry interrupted native calls.
      elseif is_error(binding, 'again', errno) then
        return nil, 'would_block', errno
      elseif is_error(binding, 'closed', errno) then
        return nil, 'closed', errno
      elseif is_error(binding, 'broken_pipe', errno) then
        return nil, 'broken_pipe', errno
      else
        return nil, error_detail(binding, errno, message), errno
      end
    end
  end

  function operations.shutdown_read(self)
    if not raw.shutdown then
      return true
    end
    local ok, errno, message = raw.shutdown(self.handle, 'read')
    if ok or is_error(binding, 'not_socket', errno) or is_error(binding, 'not_connected', errno) then
      return true
    end
    return nil, error_detail(binding, errno, message), errno
  end

  function operations.shutdown_write(self)
    if not raw.shutdown then
      return true
    end
    local ok, errno, message = raw.shutdown(self.handle, 'write')
    if ok or is_error(binding, 'not_socket', errno) or is_error(binding, 'not_connected', errno) then
      return true
    end
    return nil, error_detail(binding, errno, message), errno
  end

  function operations.close(self)
    if self._native_closed then
      return true
    end
    self._native_closed = true
    local ok, errno, message = raw.close(self.handle)
    if ok == nil or ok == false then
      return nil, error_detail(binding, errno, message), errno
    end
    return true
  end

  function operations.set_nonblocking(self, value)
    local ok, errno, message = raw.set_nonblocking(self.handle, value ~= false)
    if not ok then
      return nil, error_detail(binding, errno, message), errno
    end
    return true
  end

  function Fd.is_supported()
    return raw.supported == nil or raw.supported()
  end

  function Fd.new(value, opts)
    opts = opts or {}
    value = (raw.validate or function(v)
      return assert(v, 'native descriptor required')
    end)(value)
    generation = generation + 1
    local poll_value = raw.poll_value and raw.poll_value(value) or value
    local number = raw.number and raw.number(value) or nil
    local handle = Handle.new({
      name = opts.name or (binding.name .. '-fd-' .. tostring(number or poll_value)),
      key = opts.key or { family = binding.family, poll = poll_value, number = number, generation = generation },
      handle = value,
      host = opts.host,
      read = operations.read,
      write = operations.write,
      shutdown_read = operations.shutdown_read,
      shutdown_write = operations.shutdown_write,
      close = operations.close,
      set_nonblocking = operations.set_nonblocking,
    })
    handle.family, handle.generation = binding.family, generation
    if number ~= nil then
      handle.fd = number
    end
    if raw.opened then
      raw.opened(handle, value)
    end
    if opts.cloexec ~= false and raw.set_cloexec then
      local ok, errno, message = raw.set_cloexec(value, true)
      if not ok then
        handle:close('descriptor configuration failed')
        return nil, error_detail(binding, errno, message), errno
      end
    end
    if opts.nonblocking ~= false then
      local ok, err, extra = handle:set_nonblocking(true)
      if not ok then
        handle:close('descriptor configuration failed')
        return nil, err, extra
      end
    end
    return handle
  end

  function Fd.pipe(opts)
    opts = opts or {}
    local reader_raw, writer_raw, errno, message = raw.pipe(opts.host)
    if not reader_raw then
      return nil, nil, system_error(binding, 'pipe', 'create', errno, message), errno
    end
    local reader, read_err = Fd.new(reader_raw, {
      host = opts.host,
      name = opts.name and (opts.name .. ':read') or nil,
      nonblocking = opts.nonblocking,
    })
    if not reader then
      pcall(raw.close, writer_raw)
      return nil, nil, read_err
    end
    local writer, write_err = Fd.new(writer_raw, {
      host = opts.host,
      name = opts.name and (opts.name .. ':write') or nil,
      nonblocking = opts.nonblocking,
    })
    if not writer then
      reader:close('paired pipe wrap failed')
      return nil, nil, write_err
    end
    reader.capabilities.write, reader.capabilities.shutdown_write = false, false
    writer.capabilities.read, writer.capabilities.shutdown_read = false, false
    return reader, writer
  end

  return Fd
end

local function make_network(binding, Fd)
  local net, Network = binding.net, {}
  if not net then
    return nil
  end

  local function socket_error(action, errno, message, fields)
    if is_error(binding, 'again', errno) then
      return IOError.would_block('socket', action, fields)
    elseif is_error(binding, 'closed', errno) then
      return IOError.closed('socket', action, fields)
    end
    return system_error(binding, 'socket', action, errno, message, fields)
  end

  local function raw_of(handle)
    return handle.handle
  end

  local function query(value, peer, family)
    local address = net.query(value, peer)
    return address and net.decode(address, family) or nil
  end

  local function close_raw(value)
    pcall(binding.fd.close, value)
  end

  local function close_failed(handle, err)
    if handle then
      handle:close(err)
    end
    return nil, err
  end

  local function option(value, level, name, enabled, action, fields)
    if not net.set_option then
      return nil, IOError.unsupported('socket', action, fields)
    end
    local ok, errno, message = net.set_option(value, level, name, enabled)
    return ok and true or nil, ok and nil or socket_error(action, errno, message, fields)
  end

  local function wrap(value, host, name, family)
    local handle, err = Fd.new(value, { host = host, name = name, nonblocking = true, cloexec = true })
    if not handle then
      return nil, IOError.normalise(err, { domain = 'socket', action = 'wrap' })
    end
    handle.family, handle.socket_family = binding.family .. '-socket', family
    handle.local_address = function(self)
      return query(raw_of(self), false, family)
    end
    handle.peer_address_value = function(self)
      return query(raw_of(self), true, family)
    end
    return handle
  end

  function Network.supports_ipv4()
    return net.supports('inet4')
  end
  function Network.supports_ipv6()
    return net.supports('inet6')
  end
  function Network.supports_unix()
    return net.supports('unix')
  end
  function Network.create_listener(host, address, opts)
    opts = opts or {}
    local endpoint, err = net.encode(address)
    if not endpoint then
      return nil, err
    end
    if not net.supports(endpoint.family) then
      return nil, IOError.unsupported('socket', 'listen', { address = address })
    end
    local value, errno, message = net.open(endpoint.family, 'stream', host)
    if not value then
      return nil, socket_error('socket', errno, message)
    end
    local handle
    handle, err = wrap(value, host, opts.name or (binding.name .. '-listener'), endpoint.family)
    if not handle then
      close_raw(value)
      return nil, err
    end
    if not net.is_unix(endpoint.family) and opts.reuse_address ~= false then
      local ok
      ok, err = option(value, 'socket', 'reuse_address', true, 'setsockopt_reuseaddr', { address = address })
      if not ok then
        return close_failed(handle, err)
      end
    elseif net.is_unix(endpoint.family) and opts.unlink_existing == true and net.unlink then
      net.unlink(address.path)
    end
    local ok
    ok, errno, message = net.bind(value, endpoint.native)
    if not ok then
      return close_failed(handle, socket_error('bind', errno, message, { address = address }))
    end
    ok, errno, message = net.listen(value, tonumber(opts.backlog) or 128)
    if not ok then
      return close_failed(handle, socket_error('listen', errno, message, { address = address }))
    end
    local unix_path = net.is_unix(endpoint.family) and address.path or nil
    if unix_path and opts.unlink_on_close ~= false and net.unlink then
      handle._after_close = function()
        net.unlink(unix_path)
      end
    end
    handle.address = query(value, false, endpoint.family) or address
    handle.local_address = function(self)
      return self.address
    end
    handle.accept = function(self)
      self:clear_readable()
      local child_raw, peer, accept_errno, accept_message = net.accept(raw_of(self))
      if not child_raw then
        if is_error(binding, 'again', accept_errno) then
          return nil, nil, IOError.would_block('socket', 'accept', { address = self.address })
        end
        return nil, nil, socket_error('accept', accept_errno, accept_message, { address = self.address })
      end
      local child, child_err = wrap(
        child_raw,
        host,
        (opts.name or 'listener') .. ':accepted',
        endpoint.family
      )
      if not child then
        close_raw(child_raw)
        return nil, nil, child_err
      end
      if not net.is_unix(endpoint.family) and opts.nodelay ~= false then
        local set, nodelay_err = option(
          child_raw,
          'tcp',
          'nodelay',
          true,
          'setsockopt_nodelay',
          { address = self.address }
        )
        if not set then
          child:close(nodelay_err)
          return nil, nil, nodelay_err
        end
      end
      peer = net.decode(peer, endpoint.family) or query(child_raw, true, endpoint.family)
      child.peer_address = peer
      child.local_address_value = query(child_raw, false, endpoint.family)
      if net.prime then
        net.prime(child)
      end
      return child, peer
    end
    return handle
  end

  function Network.start_dial(host, address, opts)
    opts = opts or {}
    local endpoint, err = net.encode(address)
    if not endpoint then
      return nil, err
    end
    if not net.supports(endpoint.family) then
      return nil, IOError.unsupported('socket', 'dial', { address = address })
    end
    local value, errno, message = net.open(endpoint.family, 'stream', host)
    if not value then
      return nil, socket_error('socket', errno, message)
    end
    local handle
    handle, err = wrap(value, host, opts.name or (binding.name .. '-dial'), endpoint.family)
    if not handle then
      close_raw(value)
      return nil, err
    end
    if opts.local_address then
      local local_endpoint, local_err = net.encode(opts.local_address)
      if not local_endpoint then
        return close_failed(handle, local_err)
      end
      if local_endpoint.family ~= endpoint.family then
        return close_failed(handle, IOError.invalid_argument('socket', 'bind', {
          address = opts.local_address,
          message = 'local and peer address families differ',
        }))
      end
      local bound, bind_errno, bind_message = net.bind(value, local_endpoint.native)
      if not bound then
        return close_failed(
          handle,
          socket_error('bind', bind_errno, bind_message, { address = opts.local_address })
        )
      end
    end
    if not net.is_unix(endpoint.family) and opts.nodelay ~= false then
      local ok
      ok, err = option(value, 'tcp', 'nodelay', true, 'setsockopt_nodelay', { address = address })
      if not ok then
        return close_failed(handle, err)
      end
    end
    handle.target_address = address
    local connected, connect_errno, connect_message = net.connect(value, endpoint.native)
    local state
    if connected or is_error(binding, 'connected', connect_errno) then
      state = 'connected'
    elseif is_error(binding, 'connect_pending', connect_errno) then
      state = 'pending'
    else
      return close_failed(
        handle,
        socket_error('connect', connect_errno, connect_message, { address = address })
      )
    end
    handle._connect_complete, handle._connect_pending = state == 'connected', state == 'pending'
    if handle._connect_complete and net.prime then
      net.prime(handle)
    end
    handle.finish_connect = function(self)
      if self._connect_complete then
        return self, query(raw_of(self), true, endpoint.family) or address
      end
      self:clear_writable()
      local socket_errno, socket_message = net.socket_error(raw_of(self))
      if socket_errno == nil or socket_errno == 0 or is_error(binding, 'connected', socket_errno) then
        self._connect_complete, self._connect_pending = true, false
        if net.prime then
          net.prime(self)
        end
        return self, query(raw_of(self), true, endpoint.family) or address
      end
      if is_error(binding, 'connect_pending', socket_errno) then
        return nil, nil, IOError.would_block('socket', 'connect', { address = address })
      end
      return nil, nil, socket_error('connect', socket_errno, socket_message, { address = address })
    end
    return handle
  end

    if net.datagram then
    local function datagram_error(action, errno, message, fields)
      if is_error(binding, 'again', errno) then
        return IOError.would_block('datagram', action, fields)
      elseif is_error(binding, 'closed', errno) then
        return IOError.closed('datagram', action, fields)
      elseif is_error(binding, 'message_too_large', errno) then
        return IOError.message_too_large('datagram', action, fields)
      end
      return system_error(binding, 'datagram', action, errno, message, fields)
    end

    function Network.create_datagram(host, address, opts)
      opts = opts or {}
      local endpoint, err = net.encode(address)
      if not endpoint then
        return nil, err
      end
      local value, errno, message = net.open(endpoint.family, 'datagram', host)
      if not value then
        return nil, datagram_error('open', errno, message, { address = address })
      end
      local function fail(detail)
        pcall(binding.fd.close, value)
        return nil, detail
      end
      if opts.reuse_address == true then
        local ok
        ok, errno, message = net.set_option(value, 'socket', 'reuse_address', true)
        if not ok then
          return fail(datagram_error('setsockopt_reuseaddr', errno, message, { address = address }))
        end
      end
      local ok
      ok, errno, message = net.bind(value, endpoint.native)
      if not ok then
        return fail(datagram_error('bind', errno, message, { address = address }))
      end
      local handle
      handle, err = Fd.new(value, {
        host = host,
        name = opts.name or (binding.name .. '-datagram'),
        nonblocking = true,
        cloexec = true,
      })
      if not handle then
        return fail(err)
      end
      local function raw_of(self)
        return self.handle
      end
      local native_address = net.query(value, false)
      handle.address = native_address and net.decode(native_address, endpoint.family) or address
      handle.local_address = function(self)
        return self.address
      end
      handle.recv_from = function(self, maximum)
        self:clear_readable()
        local data, peer, flags, recv_errno, recv_message = net.receive(raw_of(self), maximum)
        if data == nil then
          return nil, datagram_error('recv_from', recv_errno, recv_message, { address = self.address })
        end
        flags = flags or {}
        if not (type(binding.capabilities) == 'table'
          and binding.capabilities.datagram_truncation == true) then
          flags.truncation_unknown = true
          flags.receive_limit = flags.receive_limit or maximum
        end
        return { data = data, peer = net.decode(peer, endpoint.family), flags = flags }
      end
      handle.send_to = function(self, data, destination)
        self:clear_writable()
        local target, target_err = net.encode(destination)
        if not target then
          return nil, target_err
        end
        if target.family ~= endpoint.family then
          return nil, IOError.protocol(
            'datagram',
            'send_to',
            'source and destination address families differ',
            { source = self.address, destination = destination }
          )
        end
        local count, send_errno, send_message = net.send(raw_of(self), data, target.native)
        if count == nil then
          return nil, datagram_error('send_to', send_errno, send_message, { destination = destination })
        end
        return count
      end
      return handle
    end

  end
  return Network
end

local function make_resolver(binding)
  local raw = binding.resolver
  if not raw then
    return nil
  end
  return function(host, endpoint, opts)
    local records, errno, message = raw.query(host, endpoint, opts or {})
    if not records then
      return nil, system_error(binding, 'resolver', 'resolve', errno, message, { endpoint = endpoint })
    end
    local out, seen = {}, {}
    local iterator = raw.records or ipairs
    for _, record in iterator(records) do
      local address = raw.address(record, endpoint.service)
      if address then
        local key = Address.key(address)
        if not seen[key] then
          seen[key], out[#out + 1] = true, address
        end
      end
    end
    if #out == 0 then
      return nil, IOError.system(
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
end

local function process_supported(process)
  return process and (type(process.is_supported) ~= 'function' or process.is_supported()) or false
end

local function capabilities(binding, features)
  local out = { time = true, readiness = true }
  if features.fd then
    out.fd, out.pipe = true, true
  end
  if features.socket then
    out.socket = true
    if features.network:supports_ipv4() then
      out.socket_ipv4 = true
    end
    if features.network:supports_ipv6() then
      out.socket_ipv6 = true
    end
    if features.network:supports_unix() then
      out.socket_unix = true
    end
  end
  if features.datagram then
    out.datagram = true
  end
  if features.resolver then
    out.resolver, out.resolver_blocking = true, true
  end
  if features.process then
    out.process = true
  end
  if features.file or features.process then
    out.file = true
    out.file_backend = features.file and binding.capabilities and binding.capabilities.file_backend
      or features.process and 'worker'
  end
  for key, value in pairs(binding.capabilities or {}) do
    if value ~= false and value ~= nil then
      out[key] = value
    end
  end
  return out
end

Posix.unavailable = unavailable

function Posix.define(binding)
  assert(type(binding) == 'table', 'host binding table required')
  assert(type(binding.name) == 'string', 'host binding name required')
  assert(type(binding.time) == 'table', 'host binding time operations required')
  assert(type(binding.poll) == 'table', 'host binding poll operations required')

  local prefix = 'fibers.io.' .. binding.name
  local Fd = make_fd(binding)
  local Network = make_network(binding, Fd)
  local resolver = binding.resolver
      and (binding.resolver.supported == nil or binding.resolver.supported())
      and make_resolver(binding)
    or nil
  local process = binding.process and binding.process(Fd) or nil
  local file = binding.file and binding.file(Fd) or nil
  local features = {
    fd = Fd.is_supported(),
    network = Network,
    socket = Network
      and (Network.supports_ipv4() or Network.supports_ipv6() or Network.supports_unix())
      or false,
    datagram = Network and Network.create_datagram ~= nil or false,
    resolver = resolver ~= nil,
    process = process_supported(process),
    file = file ~= nil,
  }

  local Module, Host = {}, {}
  Host.__index = Host

  local function probe()
    local ok, reason
    if binding.is_supported then
      ok, reason = binding.is_supported()
    else
      ok = features.fd
    end
    return not not ok, ok and nil or reason or binding.reason
      or ('required ' .. binding.name .. ' functions unavailable')
  end

  Module.is_supported = probe

  function Module.support_reason()
    local _, reason = probe()
    return reason
  end

  function Module.new(opts)
    opts = opts or {}
    if not Module.is_supported() then
      error(prefix .. ': ' .. tostring(Module.support_reason()), 2)
    end
    local host = setmetatable({
      kind = binding.name,
      name = binding.name,
      family = binding.family,
      wait_domain = binding.wait_domain or binding.family,
      fd = Fd,
      capabilities = capabilities(binding, features),
      now = function()
        return binding.time.now()
      end,
    }, Host)
    return host
  end


  function Host:sleep(seconds)
    return binding.time.sleep(seconds)
  end

  if features.fd then
    function Host:create_pipe(opts)
      return Fd.pipe({
        host = self,
        name = opts and opts.name,
        nonblocking = opts == nil or opts.nonblocking ~= false,
      })
    end
  end

  if features.socket then
    function Host:create_listener(address, opts)
      return Network.create_listener(self, address, opts)
    end

    function Host:start_dial(address, opts)
      return Network.start_dial(self, address, opts)
    end
  end

  if features.datagram then
    function Host:create_datagram(address, opts)
      return Network.create_datagram(self, address, opts)
    end
  end

  if resolver then
    function Host:resolve(endpoint, opts)
      return resolver(self, endpoint, opts)
    end
  end

  if features.process then
    function Host:start_process(spec)
      return process.start_process(self, spec)
    end
  end

  if file or features.process then
    function Host:file_provider(runtime, opts)
      if file then
        return file(self, runtime, opts)
      end
      return require('fibers.file.worker_provider').new(runtime, opts)
    end
  end

  function Host:block(rt, waits, _status)
    if self.closed then
      error(prefix .. ': host is closed', 2)
    end
    local plan = WaitSet.build(waits or {})
    if plan.unsupported then
      return nil, 'unsupported-readiness-key'
    end
    if #plan.records == 0 then
      return WaitSet.block_without_io(self, rt, plan)
    end
    local ready, reason = binding.poll.wait(plan, WaitSet.timeout_ms(rt, plan))
    if not ready then
      return true, reason or 'poll-interrupted'
    end
    local delivered = false
    for i = 1, #ready do
      local item = ready[i]
      delivered = WaitSet.deliver(rt, item.record, item.read, item.write) or delivered
    end
    if delivered then
      return true, 'readiness'
    elseif plan.deadline ~= nil and rt:now() >= plan.deadline then
      return true, 'time'
    end
    return true, 'poll'
  end

  function Host:close()
    if self.closed then
      return true
    end
    self.closed = true
    return binding.close and binding.close(self) or true
  end

  return Module
end

return Posix
