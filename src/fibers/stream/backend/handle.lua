-- Stream backend adapter for HostHandle values.
--
-- This is the named contract boundary between host handles and reactor-driven Streams.
-- It deliberately mirrors the older socket-shaped backend, but it expects a
-- first-class handle object rather than ad hoc callbacks.

local HostHandle = require('fibers.host.handle')

local Backend = {}
Backend.__index = Backend

local next_id = 0

local function ensure_handle(h)
  if type(h) ~= 'table' or h._fibers_host_handle ~= true then
    error('handle backend expects a HostHandle', 3)
  end
  if type(h.supports) ~= 'function' then
    error('HostHandle must expose supports(capability)', 3)
  end
  return h
end

function Backend.new(handle, opts)
  opts = opts or {}
  if handle and handle._fibers_host_handle ~= true and (opts.read or opts.write) then
    -- Allow constructor shorthand: Backend.new(nil, callbacks).  This is mostly
    -- for tests; ordinary code should pass a HostHandle.
    handle = HostHandle.new(opts)
  else
    handle = ensure_handle(handle)
  end
  next_id = next_id + 1
  return setmetatable({
    name = opts.name or handle.name or ('handle-backend-' .. tostring(next_id)),
    key = opts.key or (handle.readiness_key and handle:readiness_key()) or handle.key,
    handle = handle,
    read_supported = handle:supports('read') and handle:supports('readiness'),
    write_supported = handle:supports('write') and handle:supports('readiness'),
    close_supported = handle:supports('close'),
    runtime = nil,
    stream = nil,
  }, Backend)
end

function Backend:bind_runtime(rt)
  self.runtime = rt
  local h = self.handle
  if h and type(h.bind_runtime) == 'function' then
    h:bind_runtime(rt)
  end
  return self
end

function Backend:attach_stream(stream)
  self.stream = stream
  local h = self.handle
  if h and type(h.attach_stream) == 'function' then
    h:attach_stream(stream)
  end
  return self
end

function Backend:read_ready_op()
  return self.handle:read_ready_op()
end

function Backend:write_ready_op()
  return self.handle:write_ready_op()
end

function Backend:read(max)
  return self.handle:read(max)
end

function Backend:write(bytes)
  return self.handle:write(bytes)
end

function Backend:shutdown_read(reason)
  if type(self.handle.shutdown_read) == 'function' then
    return self.handle:shutdown_read(reason)
  end
  return true
end

function Backend:shutdown_write(reason)
  if type(self.handle.shutdown_write) == 'function' then
    return self.handle:shutdown_write(reason)
  end
  return true
end

function Backend:close(reason)
  if type(self.handle.close) == 'function' then
    return self.handle:close(reason)
  end
  return nil, 'unsupported_close'
end

return Backend
