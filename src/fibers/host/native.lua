-- Shared host semantics over one narrow native provider table.
--
-- Providers expose native mechanisms and canonical raw results.  This module
-- owns Fibers handles, error values, socket/datagram policy, resolver
-- deduplication, process integration and host capability reporting.

local Adapter = require('fibers.host.adapter')
local Handle = require('fibers.host.handle')
local FlowErrors = require('fibers.resource.flow.errors')
local HostError = require('fibers.host.error')

local FdClass = {}

function FdClass.define(spec)
  local Fd = {}
  local generation = 0

  function Fd.is_supported()
    return spec.is_supported()
  end

  function Fd.support_reason()
    if Fd.is_supported() then
      return nil
    end
    return spec.support_reason()
  end

  function Fd.new(raw, opts)
    opts = opts or {}
    raw = spec.validate(raw)
    generation = generation + 1
    local detail = spec.describe(raw, generation)
    local handle = Handle.new({
      name = opts.name or detail.name,
      key = opts.key or detail.key,
      handle = raw,
      host = opts.host,
      operations = spec.operations,
    })
    handle.family = spec.family
    handle.generation = generation
    spec.decorate(handle, raw, detail)
    local ok, err, extra = spec.configure(handle, opts)
    if not ok then
      handle:close('descriptor configuration failed')
      return nil, err, extra
    end
    return handle
  end

  function Fd.pipe(opts)
    opts = opts or {}
    local read_raw, write_raw, err, extra = spec.pipe(opts)
    if not read_raw then
      return nil, nil, err, extra
    end
    local reader, read_err = Fd.new(read_raw, {
      host = opts.host,
      name = opts.name and (opts.name .. ':read') or nil,
      nonblocking = opts.nonblocking,
    })
    if not reader then
      spec.close_raw(write_raw)
      return nil, nil, read_err
    end
    local writer, write_err = Fd.new(write_raw, {
      host = opts.host,
      name = opts.name and (opts.name .. ':write') or nil,
      nonblocking = opts.nonblocking,
    })
    if not writer then
      reader:close('paired pipe wrap failed')
      return nil, nil, write_err
    end
    reader.capabilities.write = false
    reader.capabilities.shutdown_write = false
    writer.capabilities.read = false
    writer.capabilities.shutdown_read = false
    return reader, writer
  end

  if spec.extend then
    spec.extend(Fd)
  end
  return Fd
end

local Native = {}

local function unsupported(prefix, reason)
  return Adapter.unsupported(prefix, reason, { 'new' })
end

local function error_detail(provider, errno, fallback)
  local errors = provider.errors or {}
  local message = errors.message and errors.message(errno)
  local name = errors.name and errors.name(errno)
  return fallback or message or (errno and ('errno ' .. tostring(errno)) or 'native operation failed'), name
end

local function system_error(provider, domain, action, errno, message, fields)
  local detail, name = error_detail(provider, errno, message)
  return HostError.system(domain, action, detail, name, errno, fields)
end

local function is_error(provider, group, errno)
  local set = provider.errors and provider.errors[group]
  return type(set) == 'function' and set(errno) or type(set) == 'table' and set[errno] == true
end

local function make_fd(provider)
  local raw = assert(provider.fd, 'native provider requires fd operations')
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
      end
      if is_error(provider, 'interrupted', errno) then
        -- retry
      elseif is_error(provider, 'again', errno) then
        return nil, 'would_block', errno
      elseif is_error(provider, 'closed', errno) then
        return nil, 'closed', errno
      else
        return nil, error_detail(provider, errno, message), errno
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
      end
      if is_error(provider, 'interrupted', errno) then
        -- retry
      elseif is_error(provider, 'again', errno) then
        return nil, 'would_block', errno
      elseif is_error(provider, 'closed', errno) then
        return nil, 'closed', errno
      elseif is_error(provider, 'broken_pipe', errno) then
        return nil, 'broken_pipe', errno
      else
        return nil, error_detail(provider, errno, message), errno
      end
    end
  end

  function operations.shutdown_read(self)
    if not raw.shutdown then
      return true
    end
    local ok, errno, message = raw.shutdown(self.handle, 'read')
    if ok or is_error(provider, 'not_socket', errno) or is_error(provider, 'not_connected', errno) then
      return true
    end
    return nil, error_detail(provider, errno, message), errno
  end

  function operations.shutdown_write(self)
    if not raw.shutdown then
      return true
    end
    local ok, errno, message = raw.shutdown(self.handle, 'write')
    if ok or is_error(provider, 'not_socket', errno) or is_error(provider, 'not_connected', errno) then
      return true
    end
    return nil, error_detail(provider, errno, message), errno
  end

  function operations.close(self)
    if self._native_closed then
      return true
    end
    self._native_closed = true
    local ok, errno, message = raw.close(self.handle)
    if ok == nil or ok == false then
      return nil, error_detail(provider, errno, message), errno
    end
    return true
  end

  function operations.set_nonblocking(self, value)
    local ok, errno, message = raw.set_nonblocking(self.handle, value ~= false)
    if not ok then
      return nil, error_detail(provider, errno, message), errno
    end
    return true
  end

  local function configure(handle, opts)
    if opts.cloexec ~= false and raw.set_cloexec then
      local ok, errno, message = raw.set_cloexec(handle.handle, true)
      if not ok then
        return nil, error_detail(provider, errno, message), errno
      end
    end
    if opts.nonblocking ~= false then
      return handle:set_nonblocking(true)
    end
    return true
  end

  return FdClass.define({
    family = provider.family,
    operations = operations,
    is_supported = function()
      return raw.supported == nil or raw.supported()
    end,
    support_reason = function()
      return raw.reason or ('required ' .. tostring(provider.name) .. ' descriptor operations unavailable')
    end,
    validate = raw.validate or function(value)
      return assert(value, 'native descriptor required')
    end,
    describe = function(value, generation)
      local key = raw.key and raw.key(value) or value
      return {
        name = (provider.name or 'native') .. '-fd-' .. tostring(raw.number and raw.number(value) or key),
        key = { family = provider.family, fd = key, generation = generation },
      }
    end,
    decorate = function(handle, value)
      handle.raw = value
      if raw.number then
        local number = raw.number(value)
        handle.fd, handle.raw_fd = number, number
      end
      if raw.decorate then
        raw.decorate(handle, value)
      end
    end,
    configure = configure,
    pipe = function(opts)
      local reader, writer, errno, message = raw.pipe(opts and opts.host)
      if not reader then
        return nil, nil, system_error(provider, 'pipe', 'create', errno, message), errno
      end
      return reader, writer
    end,
    close_raw = function(value)
      pcall(raw.close, value)
    end,
    extend = raw.extend,
  })
end

local function make_socket(provider, Fd)
  local net = provider.net
  if not net then
    return Adapter.socket({
      prefix = 'fibers.host.' .. provider.name .. '.socket',
      unavailable = 'native socket operations unavailable',
    })
  end

  local function socket_error(action, errno, message, fields)
    if is_error(provider, 'again', errno) then
      return HostError.would_block('socket', action, fields)
    end
    if is_error(provider, 'closed', errno) then
      return HostError.closed('socket', action, fields)
    end
    return system_error(provider, 'socket', action, errno, message, fields)
  end

  local function option(raw_handle, level, name, value, action, fields)
    if not net.set_option then
      return nil, HostError.unsupported('socket', action, fields)
    end
    local ok, errno, message = net.set_option(raw_handle, level, name, value)
    if not ok then
      return nil, socket_error(action, errno, message, fields)
    end
    return true
  end

  return Adapter.socket({
    prefix = 'fibers.host.' .. provider.name .. '.socket',
    name = provider.name,
    handle_family = provider.family .. '-socket',
    support_reason = net.reason or 'native stream socket operations unavailable',
    supports = net.supports,
    encode = net.encode,
    is_unix = net.is_unix,
    unlink = net.unlink or function() end,
    open = function(host, family)
      local value, errno, message = net.open(family, 'stream', host)
      if not value then
        return nil, socket_error('socket', errno, message)
      end
      return value
    end,
    close_raw = function(value)
      pcall(provider.fd.close, value)
    end,
    wrap = function(value, host, name)
      return Fd.new(value, { host = host, name = name, nonblocking = true, cloexec = true })
    end,
    raw = function(handle)
      return handle.raw or handle.handle
    end,
    query = function(value, peer, family)
      local address = net.query(value, peer)
      return address and net.decode(address, family) or nil
    end,
    decode_peer = net.decode,
    set_reuse = function(value, enabled, address)
      return option(value, 'socket', 'reuse_address', enabled, 'setsockopt_reuseaddr', { address = address })
    end,
    set_nodelay = function(value, enabled, address)
      return option(value, 'tcp', 'nodelay', enabled, 'setsockopt_nodelay', { address = address })
    end,
    bind = function(value, endpoint, address)
      local ok, errno, message = net.bind(value, endpoint.native)
      if not ok then
        return nil, socket_error('bind', errno, message, { address = address })
      end
      return true
    end,
    listen = function(value, backlog, address)
      local ok, errno, message = net.listen(value, backlog)
      if not ok then
        return nil, socket_error('listen', errno, message, { address = address })
      end
      return true
    end,
    accept = function(value, address)
      local child, peer, errno, message = net.accept(value)
      if not child then
        if is_error(provider, 'again', errno) then
          return nil, nil, HostError.would_block('socket', 'accept', { address = address })
        end
        return nil, nil, socket_error('accept', errno, message, { address = address })
      end
      return child, peer
    end,
    connect = function(value, endpoint, address)
      local ok, errno, message = net.connect(value, endpoint.native)
      if ok then
        return 'connected'
      end
      if is_error(provider, 'connect_pending', errno) then
        return 'pending'
      end
      if is_error(provider, 'connected', errno) then
        return 'connected'
      end
      return nil, socket_error('connect', errno, message, { address = address })
    end,
    finish_connect = function(value, _endpoint, address)
      local errno, message = net.socket_error(value)
      if errno == nil or errno == 0 or is_error(provider, 'connected', errno) then
        return 'connected'
      end
      if is_error(provider, 'connect_pending', errno) then
        return 'pending', HostError.would_block('socket', 'connect', { address = address })
      end
      return nil, socket_error('connect', errno, message, { address = address })
    end,
    prime = net.prime,
  })
end

local function make_datagram(provider, Fd)
  local net = provider.net
  if not net or not net.datagram then
    return Adapter.unsupported(
      'fibers.host.' .. provider.name .. '.datagram',
      'native datagram operations unavailable',
      {
        'create_datagram',
      }
    )
  end

  local function datagram_error(action, errno, message, fields)
    if is_error(provider, 'again', errno) then
      return HostError.would_block('datagram', action, fields)
    end
    if is_error(provider, 'closed', errno) then
      return HostError.closed('datagram', action, fields)
    end
    if is_error(provider, 'message_too_large', errno) then
      return HostError.message_too_large('datagram', action, fields)
    end
    return system_error(provider, 'datagram', action, errno, message, fields)
  end

  return Adapter.datagram({
    prefix = 'fibers.host.' .. provider.name .. '.datagram',
    name = provider.name,
    is_supported = function()
      return net.datagram and (net.supported == nil or net.supported())
    end,
    support_reason = net.reason,
    encode = net.encode,
    open = function(host, family, address)
      local value, errno, message = net.open(family, 'datagram', host)
      if not value then
        return nil, datagram_error('open', errno, message, { address = address })
      end
      return value
    end,
    close_raw = function(value)
      pcall(provider.fd.close, value)
    end,
    set_reuse = function(value, enabled, address)
      local ok, errno, message = net.set_option(value, 'socket', 'reuse_address', enabled)
      if not ok then
        return nil, datagram_error('setsockopt_reuseaddr', errno, message, { address = address })
      end
      return true
    end,
    bind = function(value, endpoint, address)
      local ok, errno, message = net.bind(value, endpoint.native)
      if not ok then
        return nil, datagram_error('bind', errno, message, { address = address })
      end
      return true
    end,
    wrap = function(value, host, name)
      return Fd.new(value, { host = host, name = name, nonblocking = true, cloexec = true })
    end,
    raw = function(handle)
      return handle.raw or handle.handle
    end,
    query = function(value, family)
      local address = net.query(value, false)
      return address and net.decode(address, family) or nil
    end,
    receive = function(value, maximum, family, address)
      local data, peer, flags, errno, message = net.receive(value, maximum)
      if data == nil then
        return nil, datagram_error('recv_from', errno, message, { address = address })
      end
      flags = flags or {}
      if provider.capabilities and provider.capabilities.datagram_truncation ~= true then
        flags.truncation_unknown = true
        flags.receive_limit = flags.receive_limit or maximum
      end
      return { data = data, peer = net.decode(peer, family), flags = flags }
    end,
    send = function(value, data, endpoint, destination)
      local count, errno, message = net.send(value, data, endpoint.native)
      if count == nil then
        return nil, datagram_error('send_to', errno, message, { destination = destination })
      end
      return count
    end,
  })
end

local function make_resolver(provider)
  local resolver = provider.resolver
  if not resolver then
    return nil
  end
  return Adapter.resolver({
    is_supported = function()
      return resolver.supported == nil or resolver.supported()
    end,
    reason = resolver.reason,
    query = function(host, endpoint, opts)
      local records, errno, message = resolver.query(host, endpoint, opts)
      if records then
        return records
      end
      return nil, system_error(provider, 'resolver', 'resolve', errno, message, { endpoint = endpoint })
    end,
    records = resolver.records or function(records)
      return ipairs(records)
    end,
    address = resolver.address,
  })
end

function Native.define(provider)
  assert(type(provider) == 'table', 'native provider table required')
  assert(type(provider.name) == 'string', 'native provider name required')
  local prefix = 'fibers.host.' .. provider.name
  if provider.available == false then
    return unsupported(prefix, provider.reason or 'native provider unavailable')
  end

  local Fd = make_fd(provider)
  local Socket = make_socket(provider, Fd)
  local Datagram = make_datagram(provider, Fd)
  local Resolver = make_resolver(provider)
  local Process = provider.process
      and provider.process(Fd, require('fibers.host.process').core, require('fibers.host.process').io)
    or nil

  local methods = {}
  for name, method in pairs(provider.methods or {}) do
    methods[name] = method
  end
  if provider.methods_factory then
    for name, method in
      pairs(provider.methods_factory({
        fd = Fd,
        socket = Socket,
        datagram = Datagram,
        resolver = Resolver,
        process = Process,
      }) or {})
    do
      methods[name] = method
    end
  end

  local spec = {
    name = provider.name,
    prefix = prefix,
    family = provider.family,
    is_supported = provider.is_supported or function()
      return Fd.is_supported()
    end,
    support_reason = provider.support_reason or function()
      return provider.reason
    end,
    now = assert(provider.time and provider.time.now, 'native provider requires monotonic clock'),
    sleep = assert(provider.time and provider.time.sleep, 'native provider requires sleep'),
    poll = provider.poll and provider.poll.wait,
    poll_keys = {
      key_of = provider.poll.key or provider.fd.key,
      fd_of = provider.poll.number or provider.fd.number,
    },
    fd = Fd,
    socket = Socket,
    datagram = Datagram,
    resolver = Resolver,
    process = Process,
    datagram_truncation = provider.capabilities and provider.capabilities.datagram_truncation == true,
    capabilities = provider.capabilities,
    capability_builder = provider.capability_builder,
    create = provider.create,
    close = provider.close,
    file_provider = provider.file_provider_factory and provider.file_provider_factory(Fd)
      or provider.file_provider,
    methods = methods,
  }
  if provider.block then
    spec.block = provider.block
    return Adapter.define(spec)
  end
  return Adapter.polling(spec)
end

return Native
