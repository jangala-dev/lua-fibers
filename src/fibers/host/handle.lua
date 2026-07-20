-- Generic host handle contract.
--
-- A HostHandle is the host-side half of reactor-driven byte streams.  Readiness says
-- that trying I/O may be useful; read/write remain authoritative.
--
-- The core runtime does not know about HostHandle.  The runtime HostReactor uses handles via the
-- handle stream backend, and hosts use the readiness key exposed by the handle
-- when blocking in poll/epoll or when delivering embedded callbacks.

local Readiness = require('fibers.external.readiness')
local UnsafeExternalMutation = require('fibers.internal.unsafe_external_mutation')
local Errors = require('fibers.flow.errors')
local HostError = require('fibers.host.error')
local IOAudit = require('fibers.internal.io_audit')

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

local function clear_hint(self, mode)
  mode = normalise_mode(mode)
  if self.readiness then
    UnsafeExternalMutation.clear(self.readiness, mode)
  end
  local host = self.host
  if host and type(host.clear_readiness) == 'function' then
    host:clear_readiness(self.key, mode)
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
  local poller = runtime and runtime.host_poller
  if poller then
    poller:hint(self.key, mode)
  end
end

local function callback(self, name, ...)
  local f = self['_' .. name]
  if type(f) == 'function' then
    return f(self, ...)
  end
  local host = self.host
  local hf = host and (host['handle_' .. name] or host[name])
  if type(hf) == 'function' then
    return hf(host, self, ..., self)
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
    close_on_gc = opts.close_on_gc,
    capabilities = capabilities,
    _read = opts.read,
    _write = opts.write,
    _shutdown_read = opts.shutdown_read,
    _shutdown_write = opts.shutdown_write,
    _close = opts.close,
    _set_nonblocking = opts.set_nonblocking,
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

function Handle:capability_snapshot()
  local out = {}
  for key, value in pairs(self.capabilities or {}) do
    out[key] = value
  end
  return out
end

local function require_capability(self, capability)
  if not self:supports(capability) then
    return nil, HostError.unsupported('handle', capability, { handle = self.name })
  end
  return true
end

function Handle:is_handle()
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
  return self
end

function Handle:attach_stream(stream)
  self.stream = stream
  IOAudit.transfer(self, stream, { kind = 'host_handle', role = 'stream_backend' })
  return self
end

function Handle:ready_op(mode)
  mode = normalise_mode(mode)
  if mode == 'write' then
    return self.readiness:writable_op()
  end
  return self.readiness:readable_op()
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

function Handle:set_nonblocking(value)
  if not self:supports('set_nonblocking') then
    return nil, HostError.unsupported('handle', 'set_nonblocking', { handle = self.name })
  end
  local ok, err, detail = callback(self, 'set_nonblocking', value ~= false)
  if not ok then
    return nil,
      HostError.normalise(err, {
        domain = 'handle',
        action = 'set_nonblocking',
        detail = detail,
        handle = self.name,
      })
  end
  return ok
end

function Handle:read(max)
  local ok, err = require_capability(self, 'read')
  if not ok then
    return nil, err
  end
  clear_hint(self, 'read')
  local a, b, c = callback(self, 'read', max)
  if a == nil and b ~= nil then
    return nil,
      HostError.normalise(b, {
        domain = 'handle',
        action = 'read',
        detail = c,
        handle = self.name,
      })
  end
  return a, b, c
end

function Handle:write(bytes)
  local ok, err = require_capability(self, 'write')
  if not ok then
    return nil, err
  end
  clear_hint(self, 'write')
  local a, b, c = callback(self, 'write', bytes)
  if a == nil and b ~= nil then
    return nil,
      HostError.normalise(b, {
        domain = 'handle',
        action = 'write',
        detail = c,
        handle = self.name,
      })
  end
  return a, b, c
end

function Handle:shutdown_read(reason)
  if not self:supports('shutdown_read') then
    return true
  end
  local ok, err, detail = callback(self, 'shutdown_read', reason)
  if not ok then
    return nil,
      HostError.normalise(err, {
        domain = 'handle',
        action = 'shutdown_read',
        detail = detail,
        handle = self.name,
      })
  end
  return ok
end

function Handle:shutdown_write(reason)
  if not self:supports('shutdown_write') then
    return true
  end
  local ok, err, detail = callback(self, 'shutdown_write', reason)
  if not ok then
    return nil,
      HostError.normalise(err, {
        domain = 'handle',
        action = 'shutdown_write',
        detail = detail,
        handle = self.name,
      })
  end
  return ok
end

function Handle:close(reason)
  if self.closed then
    IOAudit.closing(self, reason)
    IOAudit.closed(self, true, nil, reason)
    return true
  end
  if self.close_error then
    IOAudit.closing(self, reason)
    IOAudit.closed(self, false, self.close_error, reason)
    return nil, self.close_error
  end
  IOAudit.closing(self, reason)
  if not self:supports('close') then
    self.close_error = HostError.unsupported('handle', 'close', { handle = self.name })
    IOAudit.closed(self, false, self.close_error, reason)
    return nil, self.close_error
  end
  local ok, err, detail = callback(self, 'close', reason)
  if not ok then
    self.close_error = HostError.normalise(err, {
      domain = 'handle',
      action = 'close',
      detail = detail,
      handle = self.name,
    })
    IOAudit.closed(self, false, self.close_error, reason)
    return nil, self.close_error
  end
  self.closed = true
  IOAudit.closed(self, true, nil, reason)
  return ok
end

-- Deterministic fake/manual handle.  This is a host-handle test double, not a
-- stream reservoir.  It simulates non-blocking host I/O and uses the ManualHost
-- readiness table when a host is supplied.
local Fake = {}
Fake.__index = Fake
setmetatable(Fake, { __index = Handle })

local next_fake = 0

local function fake_has_read_event(self)
  return #(self.input or {}) > 0 or self.eof or self.read_error
end

local function fake_auto(self)
  return self.readiness_mode ~= 'manual'
end

local function fake_update_read_ready(self)
  if not fake_auto(self) then
    return
  end
  if fake_has_read_event(self) and not self.read_blocked then
    mark_hint(self, 'read')
  else
    clear_hint(self, 'read')
  end
end

local function fake_update_write_ready(self)
  if not fake_auto(self) then
    return
  end
  if self.write_blocked or self.write_error or self.closed then
    clear_hint(self, 'write')
  else
    mark_hint(self, 'write')
  end
end

function Handle.fake(opts)
  opts = opts or {}
  next_fake = next_fake + 1
  local key = opts.key or ('fake-handle-' .. tostring(next_fake))
  local self = Handle.new({
    name = opts.name or key,
    key = key,
    host = opts.host,
    readiness = opts.readiness,
    feed = opts.feed,
    capabilities = {
      read = true,
      write = true,
      shutdown_read = true,
      shutdown_write = true,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
  })
  setmetatable(self, Fake)
  self.input = {}
  self.output = {}
  self.eof = false
  self.read_error = nil
  self.write_error = nil
  self.read_blocked = opts.read_blocked == true
  self.write_blocked = opts.write_blocked == true
  self.write_chunk_size = opts.write_chunk_size
  self.readiness_mode = opts.readiness_mode
    or opts.readiness
    or (opts.manual_readiness and 'manual' or 'auto')
  self.shutdown_read_reason = nil
  self.shutdown_write_reason = nil
  self.closed_reason = nil
  if opts.input then
    self:feed_read(opts.input)
  end
  if opts.eof then
    self:feed_eof()
  end
  if opts.read_error then
    self:feed_read_error(opts.read_error)
  end
  if opts.initial_writable ~= false then
    fake_update_write_ready(self)
  end
  return self
end

function Fake:bind_runtime(rt)
  Handle.bind_runtime(self, rt)
  fake_update_read_ready(self)
  fake_update_write_ready(self)
  return self
end

function Fake:feed_read(bytes)
  if type(bytes) ~= 'string' then
    error('fake handle feed_read expects bytes', 2)
  end
  if bytes ~= '' then
    self.input[#self.input + 1] = bytes
  end
  fake_update_read_ready(self)
end

function Fake:feed_eof()
  self.eof = true
  fake_update_read_ready(self)
end

function Fake:feed_read_error(err)
  self.read_error = err or Errors.READ_ERROR
  fake_update_read_ready(self)
end

function Fake:block_reads()
  self.read_blocked = true
  fake_update_read_ready(self)
end

function Fake:unblock_reads()
  self.read_blocked = false
  fake_update_read_ready(self)
end

function Fake:block_writes()
  self.write_blocked = true
  fake_update_write_ready(self)
end

function Fake:unblock_writes()
  self.write_blocked = false
  fake_update_write_ready(self)
end

function Fake:set_write_chunk_size(n)
  self.write_chunk_size = n
end

function Fake:fail_writes(err)
  self.write_error = err or Errors.WRITE_ERROR
  fake_update_write_ready(self)
end

function Fake:read(max)
  max = max or 4096
  if self.read_blocked then
    clear_hint(self, 'read')
    return nil, HostError.would_block('handle', 'read', { handle = self.name })
  end
  if #self.input > 0 then
    local first = self.input[1]
    local take = math.min(#first, max)
    local out = string.sub(first, 1, take)
    local rest = string.sub(first, take + 1)
    if rest == '' then
      table.remove(self.input, 1)
    else
      self.input[1] = rest
    end
    fake_update_read_ready(self)
    return out
  end
  if self.read_error then
    local err = self.read_error
    self.read_error = nil
    fake_update_read_ready(self)
    return nil, err
  end
  if self.eof then
    self.eof = false
    fake_update_read_ready(self)
    return nil, HostError.eof('handle', 'read', { handle = self.name })
  end
  fake_update_read_ready(self)
  return nil, HostError.would_block('handle', 'read', { handle = self.name })
end

function Fake:write(bytes)
  if self.write_error then
    return nil, self.write_error
  end
  if self.write_blocked then
    clear_hint(self, 'write')
    return nil, HostError.would_block('handle', 'write', { handle = self.name })
  end
  if self.closed then
    return nil, HostError.closed('handle', 'write', { handle = self.name })
  end
  local n = math.min(#bytes, self.write_chunk_size or #bytes)
  if n <= 0 then
    return 0
  end
  self.output[#self.output + 1] = string.sub(bytes, 1, n)
  fake_update_write_ready(self)
  return n
end

function Fake:written()
  return table.concat(self.output)
end

function Fake:shutdown_read(reason)
  self.shutdown_read_reason = reason or true
  return true
end

function Fake:shutdown_write(reason)
  self.shutdown_write_reason = reason or true
  return true
end

function Fake:close(reason)
  self.closed = true
  self.closed_reason = reason or true
  self:shutdown_read(reason)
  self:shutdown_write(reason)
  fake_update_read_ready(self)
  fake_update_write_ready(self)
  return true
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

-- A mode-split handle composes a read handle and a write handle into the
-- duplex HostHandle shape expected by the Stream handle backend.  This is useful
-- for pipe pairs and later subprocess stdio: readiness and I/O remain delegated
-- to the true underlying end for each direction.
local Duplex = {}
Duplex.__index = Duplex
setmetatable(Duplex, { __index = Handle })

function Handle.duplex(read_handle, write_handle, opts)
  opts = opts or {}
  if type(read_handle) ~= 'table' or type(write_handle) ~= 'table' then
    error('Handle.duplex expects read and write handles', 2)
  end
  next_id = next_id + 1
  local self = {
    name = opts.name or ('duplex-handle-' .. tostring(next_id)),
    key = opts.key or {
      read = read_handle.readiness_key and read_handle:readiness_key() or read_handle.key,
      write = write_handle.readiness_key and write_handle:readiness_key() or write_handle.key,
    },
    read_handle = read_handle,
    write_handle = write_handle,
    host = opts.host or read_handle.host or write_handle.host,
    capabilities = {
      read = type(read_handle.supports) == 'function' and read_handle:supports('read') or true,
      write = type(write_handle.supports) == 'function' and write_handle:supports('write') or true,
      shutdown_read = type(read_handle.supports) ~= 'function' or read_handle:supports('shutdown_read'),
      shutdown_write = type(write_handle.supports) ~= 'function' or write_handle:supports('shutdown_write'),
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    runtime = nil,
    stream = nil,
    _fibers_host_handle = true,
  }
  setmetatable(self, Duplex)
  IOAudit.created(self, { kind = 'duplex_host_handle' })
  return self
end

function Duplex:supports(capability)
  return self.capabilities and self.capabilities[capability] == true
end
function Duplex:capability_snapshot()
  local out = {}
  for key, value in pairs(self.capabilities or {}) do
    out[key] = value
  end
  return out
end
function Duplex:is_handle()
  return true
end
function Duplex:readiness_key()
  return self.key
end

function Duplex:bind_runtime(rt)
  self.runtime = rt
  IOAudit.bind(self, rt)
  if self.read_handle and type(self.read_handle.bind_runtime) == 'function' then
    self.read_handle:bind_runtime(rt)
  end
  if self.write_handle and type(self.write_handle.bind_runtime) == 'function' then
    self.write_handle:bind_runtime(rt)
  end
  return self
end

function Duplex:attach_stream(stream)
  self.stream = stream
  IOAudit.transfer(self, stream, { kind = 'duplex_host_handle', role = 'stream_backend' })
  if self.read_handle and type(self.read_handle.attach_stream) == 'function' then
    self.read_handle:attach_stream(stream)
  end
  if self.write_handle and type(self.write_handle.attach_stream) == 'function' then
    self.write_handle:attach_stream(stream)
  end
  return self
end

function Duplex:ready_op(mode)
  mode = normalise_mode(mode)
  if mode == 'write' then
    return self.write_handle:write_ready_op()
  end
  return self.read_handle:read_ready_op()
end
function Duplex:read_ready_op()
  return self:ready_op('read')
end
function Duplex:write_ready_op()
  return self:ready_op('write')
end
function Duplex:read(max)
  return self.read_handle:read(max)
end
function Duplex:write(bytes)
  return self.write_handle:write(bytes)
end
function Duplex:shutdown_read(reason)
  if type(self.read_handle.shutdown_read) == 'function' then
    return self.read_handle:shutdown_read(reason)
  end
  return true
end
function Duplex:shutdown_write(reason)
  if type(self.write_handle.shutdown_write) == 'function' then
    return self.write_handle:shutdown_write(reason)
  end
  return true
end
function Duplex:close(reason)
  if self.closed then
    IOAudit.closing(self, reason)
    IOAudit.closed(self, true, nil, reason)
    return true
  end
  IOAudit.closing(self, reason)
  self.closed = true
  local ok1, err1 = true, nil
  local ok2, err2 = true, nil
  if self.read_handle and type(self.read_handle.close) == 'function' then
    ok1, err1 = self.read_handle:close(reason)
  end
  if
    self.write_handle
    and self.write_handle ~= self.read_handle
    and type(self.write_handle.close) == 'function'
  then
    ok2, err2 = self.write_handle:close(reason)
  end
  if not ok1 then
    IOAudit.closed(self, false, err1, reason)
    return nil, err1
  end
  if not ok2 then
    IOAudit.closed(self, false, err2, reason)
    return nil, err2
  end
  IOAudit.closed(self, true, nil, reason)
  return true
end

Handle.Duplex = Duplex

Handle.Fake = Fake
return Handle
