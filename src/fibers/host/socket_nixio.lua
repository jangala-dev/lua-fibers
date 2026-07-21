-- Nixio stream-socket provider.
--
-- Socket creation remains numeric-address only at the Fibers boundary. Nixio's
-- resolver is exposed separately through resolver_nixio.

local HostError = require('fibers.host.error')
local Provider = require('fibers.host.provider')

local function unsupported(reason)
  local value = Provider.unsupported('fibers.host.socket_nixio', reason, { 'create_listener', 'start_dial' })
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

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return unsupported('requires nixio')
end
local Fd = require('fibers.host.fd_nixio')
local NixioError = require('fibers.host.nixio_error')
local Socket = {}
local const = nixio.const or {}

local EAGAIN = const.EAGAIN or const.EWOULDBLOCK or 11
local EWOULDBLOCK = const.EWOULDBLOCK or EAGAIN
local EINTR = const.EINTR or 4
local EINPROGRESS = const.EINPROGRESS or 115
local EALREADY = const.EALREADY or 114
local EISCONN = const.EISCONN or 106

local function system_error(action, a, b, fields)
  return NixioError.system('socket', action, a, b, fields)
end

local norm_error = NixioError.split

local function would_block(action, fields)
  return HostError.would_block('socket', action, fields)
end
local function kind(address)
  return address and (address.kind or address.family)
end

local function nixio_address(address)
  local family = kind(address)
  if family == 'inet4' then
    return 'inet', address.host, tonumber(address.port)
  end
  if family == 'inet6' then
    if (tonumber(address.flowinfo) or 0) ~= 0 or (tonumber(address.scope_id) or 0) ~= 0 then
      return nil, nil, nil, HostError.unsupported('socket', 'ipv6_scope', { address = address })
    end
    return 'inet6', address.host, tonumber(address.port)
  end
  if family == 'unix' then
    return 'unix', address.path, 0
  end
  return nil, nil, nil, HostError.invalid_argument('socket', 'address', { address = address })
end

local function address_from(family, host, port)
  if family == 'inet' or family == 'inet4' then
    return { kind = 'inet4', family = 'inet4', host = host, port = tonumber(port) or 0 }
  end
  if family == 'inet6' then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = host,
      port = tonumber(port) or 0,
      flowinfo = 0,
      scope_id = 0,
    }
  end
  if family == 'unix' then
    return { kind = 'unix', family = 'unix', path = host }
  end
  return nil
end

local function query_address(obj, peer, family)
  local fn = peer and obj.getpeername or obj.getsockname
  if type(fn) ~= 'function' then
    return nil
  end
  local ok, host, port = pcall(fn, obj)
  if not ok or host == nil then
    return nil
  end
  return address_from(family, host, port)
end

local function set_option(obj, level, option, value, action, fields)
  if type(obj.setopt) ~= 'function' then
    return nil, HostError.unsupported('socket', action, fields)
  end
  value = NixioError.option(value)
  local ok, a, b = obj:setopt(level, option, value)
  if ok == nil or ok == false then
    return nil, system_error(action, a, b, fields)
  end
  return true
end

local function wrap_socket(obj, host, name, family)
  local handle, err = Fd.new(obj, { host = host, name = name, nonblocking = true })
  if not handle then
    return nil, HostError.normalise(err, { domain = 'socket', action = 'wrap' })
  end
  handle.family = 'nixio-socket'
  handle.socket_family = family
  handle.local_address = function(self)
    return query_address(self.obj, false, family)
  end
  handle.peer_address_value = function(self)
    return query_address(self.obj, true, family)
  end
  return handle
end

local function prime_connected(handle)
  -- The original Nixio backend always attempted a non-blocking read/write
  -- before waiting.  The v1 reactor is readiness-first, so seed one harmless
  -- hint in each direction when a stream socket becomes connected.  The host
  -- call remains authoritative: a read with no bytes simply reports
  -- would_block and arms poll normally.
  handle:mark_readable()
  handle:mark_writable()
  return handle
end

local function probe_family(family)
  if type(nixio.socket) ~= 'function' or not Fd.is_supported() then
    return false
  end
  local ok, obj = pcall(nixio.socket, family, 'stream')
  if not ok or not obj then
    return false
  end
  local supported = type(obj.bind) == 'function'
    and type(obj.listen) == 'function'
    and type(obj.accept) == 'function'
    and type(obj.connect) == 'function'
    and type(obj.getopt) == 'function'
    and type(obj.getsockname) == 'function'
    and type(obj.getpeername) == 'function'
  pcall(function()
    obj:close()
  end)
  return supported
end

local support_cache = {}
local function supports(family)
  if support_cache[family] == nil then
    support_cache[family] = probe_family(family)
  end
  return support_cache[family]
end

function Socket.supports_ipv4()
  return supports('inet')
end
function Socket.supports_ipv6()
  return supports('inet6')
end
function Socket.supports_unix()
  return supports('unix')
end
function Socket.is_supported()
  return Socket.supports_ipv4() or Socket.supports_ipv6() or Socket.supports_unix()
end
function Socket.support_reason()
  return Socket.is_supported() and nil or 'required Nixio stream socket functions unavailable'
end

function Socket.create_listener(host, address, opts)
  opts = opts or {}
  local family, bind_host, bind_port, address_err = nixio_address(address)
  if not family then
    return nil, address_err
  end
  if not supports(family) then
    return nil, HostError.unsupported('socket', 'listen', { address = address })
  end
  local obj, a, b = nixio.socket(family, 'stream')
  if not obj then
    return nil, system_error('socket', a, b, { address = address })
  end
  local handle, wrap_err = wrap_socket(obj, host, opts.name or 'nixio-listener', family)
  if not handle then
    return nil, wrap_err
  end

  if family ~= 'unix' and opts.reuse_address ~= false then
    local ok, option_err =
      set_option(obj, 'socket', 'reuseaddr', true, 'setsockopt_reuseaddr', { address = address })
    if not ok then
      handle:close(option_err)
      return nil, option_err
    end
  end
  if family == 'unix' and opts.unlink_existing == true then
    os.remove(address.path)
  end
  local ok, bind_a, bind_b = obj:bind(bind_host, bind_port)
  if ok == nil or ok == false then
    local failure = system_error('bind', bind_a, bind_b, { address = address })
    handle:close(failure)
    return nil, failure
  end
  ok, bind_a, bind_b = obj:listen(tonumber(opts.backlog) or 128)
  if ok == nil or ok == false then
    local failure = system_error('listen', bind_a, bind_b, { address = address })
    handle:close(failure)
    return nil, failure
  end

  local raw_close = handle._close
  local unix_path = family == 'unix' and address.path or nil
  handle._close = function(self, reason)
    local closed, close_err, detail = raw_close(self, reason)
    if unix_path and opts.unlink_on_close ~= false then
      os.remove(unix_path)
    end
    return closed, close_err, detail
  end
  handle.address = query_address(obj, false, family) or address
  handle.local_address = function(self)
    return self.address
  end
  handle.accept = function(self)
    self:clear_readable()
    while true do
      local child_obj, peer_or_err, port_or_eno = self.obj:accept()
      if child_obj then
        local child, child_err =
          wrap_socket(child_obj, host, (opts.name or 'listener') .. ':accepted', family)
        if not child then
          return nil, nil, child_err
        end
        if family ~= 'unix' and opts.nodelay ~= false then
          local set, nodelay_err = set_option(child_obj, 'tcp', 'nodelay', true, 'setsockopt_nodelay', {
            address = self.address,
          })
          if not set then
            child:close(nodelay_err)
            return nil, nil, nodelay_err
          end
        end
        local peer = address_from(family, peer_or_err, port_or_eno) or query_address(child_obj, true, family)
        child.peer_address = peer
        child.local_address_value = query_address(child_obj, false, family)
        prime_connected(child)
        return child, peer
      end
      local msg, eno = norm_error(peer_or_err, port_or_eno)
      if eno == EINTR then
        -- retry
      elseif eno == EAGAIN or eno == EWOULDBLOCK then
        return nil, nil, would_block('accept', { address = self.address })
      else
        return nil, nil, system_error('accept', msg, eno, { address = self.address })
      end
    end
  end
  return handle
end

function Socket.start_dial(host, address, opts)
  opts = opts or {}
  local family, peer_host, peer_port, address_err = nixio_address(address)
  if not family then
    return nil, address_err
  end
  if not supports(family) then
    return nil, HostError.unsupported('socket', 'dial', { address = address })
  end
  local obj, a, b = nixio.socket(family, 'stream')
  if not obj then
    return nil, system_error('socket', a, b, { address = address })
  end
  local handle, wrap_err = wrap_socket(obj, host, opts.name or 'nixio-dial', family)
  if not handle then
    return nil, wrap_err
  end

  if opts.local_address then
    local local_family, local_host, local_port, local_err = nixio_address(opts.local_address)
    if not local_family then
      handle:close(local_err)
      return nil, local_err
    end
    if local_family ~= family then
      local failure = HostError.invalid_argument('socket', 'bind', {
        address = opts.local_address,
        message = 'local and peer address families differ',
      })
      handle:close(failure)
      return nil, failure
    end
    local bound, bind_a, bind_b = obj:bind(local_host, local_port)
    if bound == nil or bound == false then
      local failure = system_error('bind', bind_a, bind_b, { address = opts.local_address })
      handle:close(failure)
      return nil, failure
    end
  end
  if family ~= 'unix' and opts.nodelay ~= false then
    local ok, option_err =
      set_option(obj, 'tcp', 'nodelay', true, 'setsockopt_nodelay', { address = address })
    if not ok then
      handle:close(option_err)
      return nil, option_err
    end
  end

  handle.target_address = address
  handle._connect_complete = false
  handle._connect_pending = false
  local connected, connect_a, connect_b = obj:connect(peer_host, peer_port)
  if connected then
    handle._connect_complete = true
    prime_connected(handle)
  else
    local msg, eno = norm_error(connect_a, connect_b)
    if eno == EINPROGRESS or eno == EALREADY or eno == EAGAIN or eno == EWOULDBLOCK then
      handle._connect_pending = true
    elseif eno == EISCONN then
      handle._connect_complete = true
      prime_connected(handle)
    else
      local failure = system_error('connect', msg, eno, { address = address })
      handle:close(failure)
      return nil, failure
    end
  end

  handle.finish_connect = function(self)
    if self._connect_complete then
      return self, query_address(self.obj, true, family) or address
    end
    self:clear_writable()
    local value, get_a, get_b = self.obj:getopt('socket', 'error')
    if value == nil then
      return nil, nil, system_error('connect_finish', get_a, get_b, { address = address })
    end
    local e = tonumber(value) or 0
    if e == 0 or e == EISCONN then
      self._connect_complete = true
      self._connect_pending = false
      prime_connected(self)
      return self, query_address(self.obj, true, family) or address
    end
    if e == EINPROGRESS or e == EALREADY or e == EAGAIN or e == EWOULDBLOCK then
      return nil, nil, would_block('connect_finish', { address = address })
    end
    return nil, nil, system_error('connect_finish', nil, e, { address = address })
  end
  return handle
end

return Socket
