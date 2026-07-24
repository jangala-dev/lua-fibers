-- Generic host handle contract.
--
-- A HostHandle is the host-side half of reactor-driven byte streams.  Readiness says
-- that trying I/O may be useful; read/write remain authoritative.
--
-- The core runtime does not know about HostHandle. The runtime HostReactor uses
-- handles directly, and hosts use the readiness key exposed by the handle
-- when blocking in poll/epoll or when delivering embedded callbacks.

local Readiness = require('fibers.external.readiness')
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
  local f = self.operations and self.operations[name]
  if type(f) == 'function' then
    return f(self, ...)
  end
  return nil, HostError.unsupported('handle', name, { handle = self.name })
end

function Handle.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local key = opts.key or opts.handle or ('host-handle-' .. tostring(next_id))
  local operations = {}
  for name, method in pairs(opts.operations or {}) do
    operations[name] = method
  end
  for _, name in ipairs({
    'read',
    'write',
    'shutdown_read',
    'shutdown_write',
    'close',
    'set_nonblocking',
    'bind_runtime',
    'attach_stream',
    'ready',
  }) do
    if operations[name] == nil and type(opts[name]) == 'function' then
      operations[name] = opts[name]
    end
  end
  local declared = opts.capabilities or {}
  local function capability(name, fallback)
    if declared[name] ~= nil then
      return not not declared[name]
    end
    return not not fallback
  end
  local capabilities = {
    read = capability('read', type(operations.read or opts.read) == 'function'),
    write = capability('write', type(operations.write or opts.write) == 'function'),
    shutdown_read = capability(
      'shutdown_read',
      type(operations.shutdown_read or opts.shutdown_read) == 'function'
    ),
    shutdown_write = capability(
      'shutdown_write',
      type(operations.shutdown_write or opts.shutdown_write) == 'function'
    ),
    close = capability('close', type(operations.close or opts.close) == 'function'),
    set_nonblocking = capability(
      'set_nonblocking',
      type(operations.set_nonblocking or opts.set_nonblocking) == 'function'
    ),
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
    operations = operations,
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
  local bind = self.operations.bind_runtime
  if bind then
    bind(self, rt)
  end
  return self
end

function Handle:attach_stream(stream)
  self.stream = stream
  IOAudit.transfer(self, stream, { kind = 'host_handle', role = 'stream_handle' })
  local attach = self.operations.attach_stream
  if attach then
    attach(self, stream)
  end
  return self
end

function Handle:ready_op(mode)
  mode = normalise_mode(mode)
  local ready = self.operations.ready
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

-- Deterministic linked one-way pipe handles.  This is used by ManualHost and
-- by tests of acquisition and pipe semantics; native hosts provide real fds.
function Handle.pipe_pair(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = tostring(next_id)
  local state = {
    chunks = {},
    bytes = 0,
    read_closed = false,
    write_closed = false,
  }
  local reader, writer

  local function update()
    if reader then
      if not state.read_closed and (state.bytes > 0 or state.write_closed) then
        reader:mark_readable()
      else
        reader:clear_readable()
      end
    end
    if writer then
      if state.write_closed then
        writer:clear_writable()
      else
        -- A closed peer read side is error-ready: the next authoritative write
        -- must run and report broken_pipe rather than waiting forever for a
        -- readiness level which can never become successful.
        writer:mark_writable()
      end
    end
  end

  reader = Handle.new({
    name = (opts.name or ('manual-pipe-' .. id)) .. ':read',
    key = opts.read_key or ('manual-pipe-' .. id .. ':read'),
    host = opts.host,
    capabilities = {
      read = true,
      write = false,
      shutdown_read = true,
      shutdown_write = false,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    read = function(_self, max)
      max = tonumber(max) or 4096
      if state.read_closed then
        return nil, HostError.closed('pipe', 'read')
      end
      if state.bytes == 0 then
        if state.write_closed then
          return nil, HostError.eof('pipe', 'read')
        end
        return nil, HostError.would_block('pipe', 'read')
      end
      local first = state.chunks[1]
      local n = math.min(max, #first)
      local out = string.sub(first, 1, n)
      local rest = string.sub(first, n + 1)
      state.bytes = state.bytes - n
      if rest == '' then
        table.remove(state.chunks, 1)
      else
        state.chunks[1] = rest
      end
      update()
      return out
    end,
    shutdown_read = function()
      state.read_closed = true
      state.chunks = {}
      state.bytes = 0
      update()
      return true
    end,
    close = function()
      state.read_closed = true
      state.chunks = {}
      state.bytes = 0
      update()
      return true
    end,
  })

  writer = Handle.new({
    name = (opts.name or ('manual-pipe-' .. id)) .. ':write',
    key = opts.write_key or ('manual-pipe-' .. id .. ':write'),
    host = opts.host,
    capabilities = {
      read = false,
      write = true,
      shutdown_read = false,
      shutdown_write = true,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    write = function(_self, bytes)
      if state.write_closed then
        return nil, HostError.closed('pipe', 'write')
      end
      if state.read_closed then
        return nil,
          HostError.new('broken_pipe', {
            domain = 'pipe',
            action = 'write',
            message = 'pipe reader is closed',
          })
      end
      if bytes == '' then
        return 0
      end
      state.chunks[#state.chunks + 1] = bytes
      state.bytes = state.bytes + #bytes
      update()
      return #bytes
    end,
    shutdown_write = function()
      state.write_closed = true
      update()
      return true
    end,
    close = function()
      state.write_closed = true
      update()
      return true
    end,
  })

  update()
  return reader, writer
end

-- Pair independent read and write handles behind the ordinary HostHandle contract.
function Handle.duplex(read_handle, write_handle, opts)
  opts = opts or {}
  if type(read_handle) ~= 'table' or type(write_handle) ~= 'table' then
    error('Handle.duplex expects read and write handles', 2)
  end
  local function each(method, value)
    for _, handle in ipairs({ read_handle, write_handle }) do
      if handle and type(handle[method]) == 'function' then
        handle[method](handle, value)
      end
    end
  end
  local handle = Handle.new({
    name = opts.name,
    key = opts.key or {
      read = read_handle:readiness_key(),
      write = write_handle:readiness_key(),
    },
    host = opts.host or read_handle.host or write_handle.host,
    capabilities = {
      read = read_handle:supports('read'),
      write = write_handle:supports('write'),
      shutdown_read = read_handle:supports('shutdown_read'),
      shutdown_write = write_handle:supports('shutdown_write'),
      close = true,
      readiness = true,
    },
    operations = {
      read = function(_, maximum)
        return read_handle:read(maximum)
      end,
      write = function(_, bytes)
        return write_handle:write(bytes)
      end,
      shutdown_read = function(_, reason)
        return read_handle:shutdown_read(reason)
      end,
      shutdown_write = function(_, reason)
        return write_handle:shutdown_write(reason)
      end,
      ready = function(_, mode)
        return mode == 'write' and write_handle:write_ready_op() or read_handle:read_ready_op()
      end,
      bind_runtime = function(_, runtime)
        each('bind_runtime', runtime)
      end,
      attach_stream = function(_, stream)
        each('attach_stream', stream)
      end,
      close = function(_, reason)
        local ok, err = read_handle:close(reason)
        if not ok then
          return nil, err
        end
        if write_handle ~= read_handle then
          return write_handle:close(reason)
        end
        return true
      end,
    },
  })
  handle.read_handle, handle.write_handle = read_handle, write_handle
  return handle
end

return Handle
