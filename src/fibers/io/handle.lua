-- Generic host handle contract.
--
-- A HostHandle is the host-side half of reactor-driven byte streams.  Readiness says
-- that trying I/O may be useful; read/write remain authoritative.
--
-- The core runtime does not know about HostHandle. The runtime HostReactor uses
-- handles directly, and hosts use the readiness key exposed by the handle
-- when blocking in poll/epoll or when delivering embedded callbacks.

local External = require('fibers.embed.external')
local IOError = require('fibers.io.error')
local IOAudit = require('fibers.internal.io_audit')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')
local Readiness = require('fibers.io.readiness')

local Handle = {}
Handle.__index = Handle

local next_id = 0

local normalise_mode = Readiness._mode

local function clear_local_hint(self, mode)
  mode = normalise_mode(mode)
  self[mode == 'read' and '_read_hint' or '_write_hint'] = false
  if self._readiness then External.unsafe_clear(self._readiness, mode) end
end

local function clear_hint(self, mode)
  mode = normalise_mode(mode)
  clear_local_hint(self, mode)
  local host = self._host
  if host and type(host.clear_readiness) == 'function' then
    host:clear_readiness(self._key, mode)
  elseif host and type(host.set_readiness) == 'function' then
    host:set_readiness(self._key, mode, false)
  end
end

local function mark_hint(self, mode)
  mode = normalise_mode(mode)
  self[mode == 'read' and '_read_hint' or '_write_hint'] = true
  if self._readiness then External.unsafe_deliver(self._readiness, mode, true) end
  local host = self._host
  if host and type(host.set_readiness) == 'function' then
    host:set_readiness(self._key, mode, true)
  end
  local runtime = self._runtime
  local reactor = runtime and runtime.host_reactor
  if reactor then
    reactor:hint(self._key, mode)
  end
end

local function callback(self, name, ...)
  return self['_' .. name](self, ...)
end

local HANDLE_OPTIONS = {
  label = Contract.non_empty_string, key = true, handle = true, host = true,
  readiness = true,
  read = Contract.func, write = Contract.func,
  shutdown_read = Contract.func, shutdown_write = Contract.func,
  close = Contract.func, set_nonblocking = Contract.func,
  bind_runtime = Contract.func, attach_stream = Contract.func, ready = Contract.func,
}

local CAPABILITY_FIELDS = {
  read = '_read', write = '_write', shutdown_read = '_shutdown_read',
  shutdown_write = '_shutdown_write', close = '_close', set_nonblocking = '_set_nonblocking',
}

function Handle.new(opts)
  opts = Contract.record(opts, HANDLE_OPTIONS, 'HostHandle options', 2)
  if opts.close == nil then error('HostHandle requires close', 2) end

  next_id = next_id + 1
  local key = opts.key or opts.handle or ('host-handle-' .. tostring(next_id))
  local id = 'host-handle-' .. tostring(next_id)
  local handle = setmetatable({
    _fibers_id = id,
    _key = key,
    _handle = opts.handle or key,
    _host = opts.host,
    _readiness = opts.readiness,
    _read_hint = false,
    _write_hint = false,
    _read = opts.read,
    _write = opts.write,
    _shutdown_read = opts.shutdown_read,
    _shutdown_write = opts.shutdown_write,
    _close = opts.close,
    _set_nonblocking = opts.set_nonblocking,
    _bind_runtime = opts.bind_runtime,
    _attach_stream = opts.attach_stream,
    _ready = opts.ready,
    _runtime = nil,
    _fibers_host_handle = true,
  }, Handle)
  Label.attach(handle, opts.label)
  IOAudit.created(handle, { kind = 'host_handle' })
  return handle
end

function Handle:supports(capability)
  if capability == 'readiness' then return true end
  local field = CAPABILITY_FIELDS[capability]
  return field ~= nil and self[field] ~= nil
end

local function require_capability(self, capability)
  if not self:supports(capability) then
    return nil, IOError.unsupported('handle', capability, { handle = Label.describe(self, self._fibers_id) })
  end
  return true
end

function Handle:readiness_key()
  return self._key
end

local function ensure_readiness(self)
  if self._readiness then return self._readiness end
  local readiness = Readiness.new(self._key, nil)
  self._readiness = readiness
  Label.child(readiness, self, 'readiness')
  if self._read_hint then External.unsafe_deliver(readiness, 'read', true) end
  if self._write_hint then External.unsafe_deliver(readiness, 'write', true) end
  return readiness
end

function Handle:bind_runtime(rt)
  if self._runtime ~= rt then
    self._runtime = rt
    local bind = self._bind_runtime
    if bind then bind(self, rt) end
  end
  IOAudit.bind(self, rt)
  return self
end

function Handle:attach_stream(stream)
  IOAudit.transfer(self, stream, { kind = 'host_handle', role = 'stream_handle' })
  local attach = self._attach_stream
  if attach then
    attach(self, stream)
  end
  return self
end

function Handle:ready_op(mode)
  mode = normalise_mode(mode)
  local ready = self._ready
  if ready then
    return ready(self, mode)
  end
  local readiness = ensure_readiness(self)
  return mode == 'write' and readiness:writable_op() or readiness:readable_op()
end

function Handle:read_ready_op()
  return self:ready_op('read')
end
function Handle:write_ready_op()
  return self:ready_op('write')
end
function Handle:mark_readable()
  mark_hint(self, 'read')
  return true
end
function Handle:mark_writable()
  mark_hint(self, 'write')
  return true
end
function Handle:clear_readable()
  clear_hint(self, 'read')
  return true
end
function Handle:clear_writable()
  clear_hint(self, 'write')
  return true
end

local function call_error(self, action, detail, extra)
  return IOError.normalise(detail, {
    domain = 'handle',
    action = action,
    detail = extra,
    _handle = Label.describe(self, self._fibers_id),
  })
end

local function data_method(action, mode)
  return function(self, value)
    local ok, err = require_capability(self, action)
    if not ok then
      return nil, err
    end
    clear_local_hint(self, mode)
    local a, b, c = callback(self, action, value)
    if a == nil and b ~= nil then
      return nil, call_error(self, action, b, c)
    end
    return a, b, c
  end
end

function Handle:set_nonblocking(value)
  local ok, err = require_capability(self, 'set_nonblocking')
  if not ok then
    return nil, err
  end
  value = Contract.boolean(value, 'HostHandle:set_nonblocking value', 2)
  local changed, detail, extra = callback(self, 'set_nonblocking', value)
  if not changed then
    return nil, call_error(self, 'set_nonblocking', detail, extra)
  end
  return changed
end

Handle.read = data_method('read', 'read')
Handle.write = data_method('write', 'write')

local function shutdown_method(action)
  return function(self, reason)
    local supported, unsupported = require_capability(self, action)
    if not supported then
      return nil, unsupported
    end
    local ok, detail, extra = callback(self, action, reason)
    if not ok then
      return nil, call_error(self, action, detail, extra)
    end
    return ok
  end
end

Handle.shutdown_read = shutdown_method('shutdown_read')
Handle.shutdown_write = shutdown_method('shutdown_write')

local function close_once(self, reason, closer)
  IOAudit.closing(self, reason)
  if self._closed then
    IOAudit.closed(self, true, nil, reason)
    return true
  end
  if self._close_error then
    IOAudit.closed(self, false, self._close_error, reason)
    return nil, self._close_error
  end
  local ok, err = closer()
  if not ok then
    self._close_error = err
    IOAudit.closed(self, false, err, reason)
    return nil, err
  end
  self._closed = true
  IOAudit.closed(self, true, nil, reason)
  return ok
end

function Handle:close(reason)
  return close_once(self, reason, function()
    if not self:supports('close') then
      return nil, IOError.unsupported('handle', 'close', { handle = Label.describe(self, self._fibers_id) })
    end
    local ok, err, detail = callback(self, 'close', reason)
    if not ok then
      return nil,
        IOError.normalise(err, {
          domain = 'handle',
          action = 'close',
          detail = detail,
          handle = Label.describe(self, self._fibers_id),
        })
    end
    if self._after_close then
      self._after_close(self, reason)
    end
    return ok
  end)
end

return Handle
