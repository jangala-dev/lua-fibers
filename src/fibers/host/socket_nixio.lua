-- Nixio native stream-socket operations.

local HostError = require('fibers.host.error')
local SocketCore = require('fibers.host.socket_core')
local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return SocketCore.define({
    prefix = 'fibers.host.socket_nixio',
    unavailable = 'nixio module not available',
  })
end

local Fd = require('fibers.host.fd_nixio')
local NixioError = require('fibers.host.nixio_error')
local EAGAIN = nixio.const and (nixio.const.EAGAIN or nixio.const.EWOULDBLOCK) or 11
local EWOULDBLOCK = nixio.const and (nixio.const.EWOULDBLOCK or nixio.const.EAGAIN) or EAGAIN
local EINTR = nixio.const and nixio.const.EINTR or 4
local pending = {
  [nixio.const and nixio.const.EINPROGRESS or 115] = true,
  [nixio.const and nixio.const.EALREADY or 114] = true,
  [EAGAIN] = true,
  [EWOULDBLOCK] = true,
}
local connected = { [nixio.const and nixio.const.EISCONN or 106] = true }
local support_cache = {}

local function split(a, b)
  return NixioError.split(a, b)
end
local function system_error(action, a, b, fields)
  local message, number = split(a, b)
  return NixioError.system('socket', action, message, number, fields)
end
local function encode(address)
  local kind = address and (address.kind or address.family)
  if kind == 'inet4' then
    return { family = 'inet', host = address.host, port = address.port }
  end
  if kind == 'inet6' then
    if (tonumber(address.scope_id) or 0) ~= 0 or (tonumber(address.flowinfo) or 0) ~= 0 then
      return nil, HostError.unsupported('socket', 'ipv6_scope_or_flowinfo', { address = address })
    end
    return { family = 'inet6', host = address.host, port = address.port }
  end
  if kind == 'unix' then
    return { family = 'unix', host = address.path }
  end
  return nil, HostError.invalid_argument('socket', 'address', { address = address })
end
local function decode(value, family, port)
  if type(value) == 'table' then
    family, port, value = value.family or family, value.port or port, value.addr or value.host or value.path
  end
  if family == 'unix' then
    return { kind = 'unix', family = 'unix', path = value }
  end
  if family == 'inet6' then
    return {
      kind = 'inet6',
      family = 'inet6',
      host = value,
      port = tonumber(port) or 0,
      flowinfo = 0,
      scope_id = 0,
    }
  end
  return { kind = 'inet4', family = 'inet4', host = value, port = tonumber(port) or 0 }
end
local function query(obj, peer, family)
  local a, b
  if peer then
    a, b = obj:getpeername()
  else
    a, b = obj:getsockname()
  end
  return a and decode(a, family, b) or nil
end
local function set_option(obj, level, option, value, action, fields)
  if type(obj.setopt) ~= 'function' then
    return nil, HostError.unsupported('socket', action, fields)
  end
  local ok, a, b = obj:setopt(level, option, NixioError.option(value))
  if ok == nil or ok == false then
    return nil, system_error(action, a, b, fields)
  end
  return true
end
local function supports(family)
  if support_cache[family] == nil then
    local ok, obj = pcall(nixio.socket, family, 'stream')
    support_cache[family] = ok
        and obj
        and type(obj.bind) == 'function'
        and type(obj.listen) == 'function'
        and type(obj.accept) == 'function'
        and type(obj.connect) == 'function'
        and Fd.is_supported()
      or false
    if obj then
      pcall(obj.close, obj)
    end
  end
  return support_cache[family]
end
local function prime(handle)
  handle:mark_readable()
  handle:mark_writable()
end

return SocketCore.define({
  prefix = 'fibers.host.socket_nixio',
  name = 'nixio',
  handle_family = 'nixio-socket',
  raw = function(handle)
    return handle.obj
  end,
  support_reason = 'required Nixio stream socket functions unavailable',
  supports = function(kind)
    return supports(({ inet4 = 'inet', inet6 = 'inet6', unix = 'unix' })[kind] or kind)
  end,
  encode = encode,
  is_unix = function(family)
    return family == 'unix'
  end,
  unlink = function(path)
    if path then
      os.remove(path)
    end
  end,
  open = function(family)
    local obj, a, b = nixio.socket(family, 'stream')
    if not obj then
      return nil, system_error('socket', a, b)
    end
    return obj
  end,
  close_raw = function(obj)
    if obj then
      pcall(obj.close, obj)
    end
  end,
  wrap = function(obj, host, name)
    return Fd.new(obj, { host = host, name = name, nonblocking = true })
  end,
  query = query,
  decode_peer = function(value, family)
    if type(value) == 'table' then
      return decode(value, family)
    end
    -- Unbound Unix-domain clients are anonymous.  Nixio returns no peer
    -- payload for them, but the accepted stream still has a Unix peer address
    -- identity.  Preserve the pre-core representation instead of returning nil.
    if family == 'unix' then
      return decode(value, family)
    end
    return value and decode(value, family) or nil
  end,
  set_reuse = function(obj, value, address)
    return set_option(obj, 'socket', 'reuseaddr', value, 'setsockopt_reuseaddr', { address = address })
  end,
  set_nodelay = function(obj, value, address)
    return set_option(obj, 'tcp', 'nodelay', value, 'setsockopt_nodelay', { address = address })
  end,
  bind = function(obj, endpoint, address)
    local ok, a, b = obj:bind(endpoint.host, endpoint.port)
    if ok == nil or ok == false then
      return nil, system_error('bind', a, b, { address = address })
    end
    return true
  end,
  listen = function(obj, backlog, address)
    local ok, a, b = obj:listen(backlog)
    if ok == nil or ok == false then
      return nil, system_error('listen', a, b, { address = address })
    end
    return true
  end,
  accept = function(obj, address)
    while true do
      local child, a, b = obj:accept()
      if child then
        return child, a and { host = a, port = b } or nil
      end
      local message, eno = split(a, b)
      if eno == EINTR then
      elseif eno == EAGAIN or eno == EWOULDBLOCK then
        return nil, nil, HostError.would_block('socket', 'accept', { address = address })
      else
        return nil, nil, system_error('accept', message, eno, { address = address })
      end
    end
  end,
  connect = function(obj, endpoint, address)
    local ok, a, b = obj:connect(endpoint.host, endpoint.port)
    if ok then
      return 'connected'
    end
    local message, eno = split(a, b)
    if connected[eno] then
      return 'connected'
    end
    if pending[eno] then
      return 'pending'
    end
    return nil, system_error('connect', message, eno, { address = address })
  end,
  finish_connect = function(obj, _endpoint, address)
    local value, a, b = obj:getopt('socket', 'error')
    if value == nil then
      return nil, system_error('connect_finish', a, b, { address = address })
    end
    local code = tonumber(value) or 0
    if code == 0 or connected[code] then
      return 'connected'
    end
    if pending[code] then
      return 'pending', HostError.would_block('socket', 'connect_finish', { address = address })
    end
    return nil, system_error('connect_finish', nil, code, { address = address })
  end,
  prime = prime,
})
