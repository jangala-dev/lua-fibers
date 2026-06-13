-- Socket-shaped stream backend over host-provided non-blocking operations.
--
-- This module does not choose a socket library.  It is the contract adapter for
-- hosts that can supply readiness plus non-blocking read/write/shutdown calls.
-- The host callbacks remain authoritative: readiness only says that trying the
-- operation may be productive.

local Source = require('fibers.base.source')
local SourceState = require('fibers.internal.source_state')

local Socket = {}
Socket.__index = Socket

local next_id = 0

local function clear_hint(self, mode)
  if self.readiness then SourceState.clear(self.readiness, mode) end
  if self.runtime and self.runtime._invalidate_cursor then self.runtime:_invalidate_cursor() end
end

local function callback(self, name, ...)
  local f = self['_' .. name]
  if type(f) == 'function' then return f(self, ...) end
  local host = self.host
  local hf = host and (host['socket_' .. name] or host[name])
  if type(hf) == 'function' then return hf(host, self.handle or self.key, ..., self) end
  return nil, 'unsupported_' .. tostring(name)
end

function Socket.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local key = opts.key or opts.handle or ('socket-backend-' .. tostring(next_id))
  return setmetatable({
    name = opts.name or ('socket-backend-' .. tostring(next_id)),
    key = key,
    handle = opts.handle or key,
    host = opts.host,
    readiness = opts.readiness or opts.source or Source.readiness(key, nil, (opts.name or tostring(key)) .. ':readiness'),
    feed = opts.feed,
    _read = opts.read,
    _write = opts.write,
    _shutdown_read = opts.shutdown_read,
    _shutdown_write = opts.shutdown_write,
    _close = opts.close,
    runtime = nil,
    stream = nil,
  }, Socket)
end

function Socket:bind_runtime(rt)
  if self.runtime == rt and self.feed then return self end
  self.runtime = rt
  if not self.feed then
    local source, feed = rt:readiness(self.key, (self.name or tostring(self.key)) .. ':readiness')
    self.readiness = source
    self.feed = feed
  end
  return self
end

function Socket:attach_stream(stream)
  self.stream = stream
  return self
end

function Socket:ready_op(mode)
  if mode == 'write' or mode == 'wr' then return self.readiness:writable_op() end
  return self.readiness:readable_op()
end

function Socket:read_ready_op()
  return self:ready_op('read')
end

function Socket:write_ready_op()
  return self:ready_op('write')
end

function Socket:read(max)
  local a, b, c = callback(self, 'read', max)
  clear_hint(self, 'read')
  return a, b, c
end

function Socket:write(bytes)
  local a, b, c = callback(self, 'write', bytes)
  clear_hint(self, 'write')
  return a, b, c
end

function Socket:shutdown_read(reason)
  local ok, err = callback(self, 'shutdown_read', reason)
  if ok == nil and err and tostring(err):match('^unsupported_') then return true end
  return ok, err
end

function Socket:shutdown_write(reason)
  local ok, err = callback(self, 'shutdown_write', reason)
  if ok == nil and err and tostring(err):match('^unsupported_') then return true end
  return ok, err
end

function Socket:close(reason)
  local ok, err = callback(self, 'close', reason)
  if ok == nil and err and tostring(err):match('^unsupported_') then
    self:shutdown_read(reason)
    self:shutdown_write(reason)
    return true
  end
  return ok, err
end

return Socket
