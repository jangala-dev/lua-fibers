-- Readiness-backed host stream backend.
--
-- This is the generic adapter from readiness-resource hints to reactor-driven
-- streams.  A Readiness resource means only that the host action is worth
-- trying; the non-blocking read/write callbacks remain authoritative and may
-- still return would_block, eof, or errors.

local Readiness = require('fibers.external.readiness')

local Backend = {}
Backend.__index = Backend

local next_id = 0

function Backend.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local key = opts.key or opts.handle or ('readiness-backend-' .. tostring(next_id))
  local readiness = opts.readiness or Readiness.new(key, nil, (opts.name or tostring(key)) .. ':readiness')
  return setmetatable({
    name = opts.name or ('readiness-backend-' .. tostring(next_id)),
    key = key,
    readiness = readiness,
    feed = opts.feed,
    _read = opts.read,
    _write = opts.write,
    _shutdown_read = opts.shutdown_read,
    _shutdown_write = opts.shutdown_write,
    _close = opts.close,
    read_supported = type(opts.read) == 'function',
    write_supported = type(opts.write) == 'function',
    close_supported = type(opts.close) == 'function',
    stream = nil,
    runtime = nil,
  }, Backend)
end

function Backend:bind_runtime(rt)
  if self.runtime == rt and self.feed then
    return self
  end
  self.runtime = rt
  if not self.feed then
    local source, feed = rt:readiness(self.key, (self.name or tostring(self.key)) .. ':readiness')
    self.readiness = source
    self.feed = feed
  end
  return self
end

function Backend:attach_stream(stream)
  self.stream = stream
end

function Backend:ready_op(mode)
  if mode == 'write' or mode == 'wr' then
    return self.readiness:writable_op()
  end
  return self.readiness:readable_op()
end

function Backend:read_ready_op()
  return self:ready_op('read')
end

function Backend:write_ready_op()
  return self:ready_op('write')
end

function Backend:read(max)
  if not self._read then
    return nil, 'would_block'
  end
  return self._read(self, max)
end

function Backend:write(bytes)
  if not self._write then
    return nil, 'would_block'
  end
  return self._write(self, bytes)
end

function Backend:shutdown_read(reason)
  if self._shutdown_read then
    return self._shutdown_read(self, reason)
  end
  return true
end

function Backend:shutdown_write(reason)
  if self._shutdown_write then
    return self._shutdown_write(self, reason)
  end
  return true
end

function Backend:close(reason)
  if self._close then
    return self._close(self, reason)
  end
  return nil, 'unsupported_close'
end

return Backend
