-- Generic host handle contract.
--
-- A HostHandle is the host-side half of reactor-driven byte streams.  Readiness says
-- that trying I/O may be useful; read/write remain authoritative.
--
-- The core runtime does not know about HostHandle. The runtime HostReactor uses
-- handles directly, and hosts use the readiness key exposed by the handle
-- when blocking in poll/epoll or when delivering embedded callbacks.

local Readiness = require('fibers.host.readiness')
local UnsafeExternalMutation = require('fibers.host.unsafe_external_mutation')
local HostError = require('fibers.host.error')
local IOAudit = require('fibers.diagnostics.io')

local Handle = {}
Handle.__index = Handle

local next_id = 0

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

local function clear_local_hint(self, mode)
  mode = normalise_mode(mode)
  if self.readiness then
    UnsafeExternalMutation.clear(self.readiness, mode)
  end
end

local function clear_hint(self, mode)
  mode = normalise_mode(mode)
  clear_local_hint(self, mode)
  local host = self.host
  if host and type(host.clear_readiness) == 'function' then
    host:clear_readiness(self.key, mode)
  elseif host and type(host.set_readiness) == 'function' then
    host:set_readiness(self.key, mode, false)
  end
end

local function mark_hint(self, mode)
  mode = normalise_mode(mode)
  if self.readiness then
    UnsafeExternalMutation.deliver(self.readiness, mode, true)
  end
  local host = self.host
  if host and type(host.set_readiness) == 'function' then
    host:set_readiness(self.key, mode, true)
  end
  local runtime = self.runtime
  local reactor = runtime and runtime.host_reactor
  if reactor then
    reactor:hint(self.key, mode)
  end
end

local function callback(self, name, ...)
  local f = self['_' .. name]
  if type(f) == 'function' then
    return f(self, ...)
  end
  return nil, HostError.unsupported('handle', name, { handle = self.name })
end

function Handle.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local key = opts.key or opts.handle or ('host-handle-' .. tostring(next_id))
  local declared = opts.capabilities or {}
  local function capability(name, fallback)
    if declared[name] ~= nil then
      return not not declared[name]
    end
    return not not fallback
  end
  local capabilities = {
    read = capability('read', type(opts.read) == 'function'),
    write = capability('write', type(opts.write) == 'function'),
    shutdown_read = capability('shutdown_read', type(opts.shutdown_read) == 'function'),
    shutdown_write = capability('shutdown_write', type(opts.shutdown_write) == 'function'),
    close = capability('close', type(opts.close) == 'function'),
    set_nonblocking = capability('set_nonblocking', type(opts.set_nonblocking) == 'function'),
    readiness = capability('readiness', true),
  }
  local handle = setmetatable({
    name = opts.name or ('host-handle-' .. tostring(next_id)),
    key = key,
    handle = opts.handle or key,
    host = opts.host,
    readiness = opts.readiness or Readiness.new(key, nil, (opts.name or tostring(key)) .. ':readiness'),
    feed = opts.feed,
    capabilities = capabilities,
    _read = opts.read,
    _write = opts.write,
    _shutdown_read = opts.shutdown_read,
    _shutdown_write = opts.shutdown_write,
    _close = opts.close,
    _set_nonblocking = opts.set_nonblocking,
    _bind_runtime = opts.bind_runtime,
    _attach_stream = opts.attach_stream,
    _ready = opts.ready,
    runtime = nil,
    stream = nil,
    _fibers_host_handle = true,
  }, Handle)
  IOAudit.created(handle, { kind = 'host_handle' })
  return handle
end

function Handle:supports(capability)
  return self.capabilities and self.capabilities[capability] == true
end

local function require_capability(self, capability)
  if not self:supports(capability) then
    return nil, HostError.unsupported('handle', capability, { handle = self.name })
  end
  return true
end

function Handle:readiness_key()
  return self.key
end

function Handle:bind_runtime(rt)
  if self.runtime == rt and self.feed then
    IOAudit.bind(self, rt)
    return self
  end
  self.runtime = rt
  IOAudit.bind(self, rt)
  if not self.feed then
    self.feed = rt:external_feed(self.readiness)
  end
  local bind = self._bind_runtime
  if bind then
    bind(self, rt)
  end
  return self
end

function Handle:attach_stream(stream)
  self.stream = stream
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
  return mode == 'write' and self.readiness:writable_op() or self.readiness:readable_op()
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
  return HostError.normalise(detail, {
    domain = 'handle',
    action = action,
    detail = extra,
    handle = self.name,
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
  local changed, detail, extra = callback(self, 'set_nonblocking', value ~= false)
  if not changed then
    return nil, call_error(self, 'set_nonblocking', detail, extra)
  end
  return changed
end

Handle.read = data_method('read', 'read')
Handle.write = data_method('write', 'write')

local function shutdown_method(action)
  return function(self, reason)
    if not self:supports(action) then
      return true
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
  if self.closed then
    IOAudit.closed(self, true, nil, reason)
    return true
  end
  if self.close_error then
    IOAudit.closed(self, false, self.close_error, reason)
    return nil, self.close_error
  end
  local ok, err = closer()
  if not ok then
    self.close_error = err
    IOAudit.closed(self, false, err, reason)
    return nil, err
  end
  self.closed = true
  IOAudit.closed(self, true, nil, reason)
  return ok
end

function Handle:close(reason)
  return close_once(self, reason, function()
    if not self:supports('close') then
      return nil, HostError.unsupported('handle', 'close', { handle = self.name })
    end
    local ok, err, detail = callback(self, 'close', reason)
    if not ok then
      return nil,
        HostError.normalise(err, {
          domain = 'handle',
          action = 'close',
          detail = detail,
          handle = self.name,
        })
    end
    if self._after_close then
      self._after_close(self, reason)
    end
    return ok
  end)
end

return Handle
