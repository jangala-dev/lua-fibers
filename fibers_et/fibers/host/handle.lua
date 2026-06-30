-- Generic host handle contract.
--
-- A HostHandle is the host-side half of pumped byte streams.  Readiness says
-- that trying I/O may be useful; read/write remain authoritative.
--
-- The core runtime does not know about HostHandle.  Streams use handles via the
-- handle stream backend, and hosts use the readiness key exposed by the handle
-- when blocking in poll/epoll or when delivering embedded callbacks.

local Source = require('fibers.atoms.source')
local SourceState = require('fibers.internal.source_state')
local Errors = require('fibers.flow.errors')

local Handle = {}
Handle.__index = Handle

local next_id = 0

local function normalise_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then error('readiness mode must be read or write', 3) end
  return mode
end

local function clear_hint(self, mode)
  mode = normalise_mode(mode)
  if self.readiness then SourceState.clear(self.readiness, mode) end
  local host = self.host
  if host and type(host.clear_readiness) == 'function' then host:clear_readiness(self.key, mode) end
end

local function mark_hint(self, mode)
  mode = normalise_mode(mode)
  if self.readiness then SourceState.arrive(self.readiness, mode, true) end
  local host = self.host
  if host and type(host.set_readiness) == 'function' then host:set_readiness(self.key, mode, true) end
end

local function callback(self, name, ...)
  local f = self['_' .. name]
  if type(f) == 'function' then return f(self, ...) end
  local host = self.host
  local hf = host and (host['handle_' .. name] or host[name])
  if type(hf) == 'function' then return hf(host, self, ..., self) end
  return nil, 'unsupported_' .. tostring(name)
end

function Handle.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local key = opts.key or opts.handle or ('host-handle-' .. tostring(next_id))
  return setmetatable({
    name = opts.name or ('host-handle-' .. tostring(next_id)),
    key = key,
    handle = opts.handle or key,
    host = opts.host,
    readiness = opts.readiness or opts.source or Source.readiness(key, nil, (opts.name or tostring(key)) .. ':readiness'),
    feed = opts.feed,
    close_on_gc = opts.close_on_gc,
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
end

function Handle:is_handle()
  return true
end

function Handle:readiness_key()
  return self.key
end

function Handle:bind_runtime(rt)
  if self.runtime == rt and self.feed then return self end
  self.runtime = rt
  if not self.feed then
    local source, feed = rt:readiness(self.key, (self.name or tostring(self.key)) .. ':readiness')
    self.readiness = source
    self.feed = feed
  end
  return self
end

function Handle:attach_stream(stream)
  self.stream = stream
  return self
end

function Handle:ready_op(mode)
  mode = normalise_mode(mode)
  if mode == 'write' then return self.readiness:writable_op() end
  return self.readiness:readable_op()
end

function Handle:read_ready_op() return self:ready_op('read') end
function Handle:write_ready_op() return self:ready_op('write') end

function Handle:mark_readable() mark_hint(self, 'read'); return true end
function Handle:mark_writable() mark_hint(self, 'write'); return true end
function Handle:clear_readable() clear_hint(self, 'read'); return true end
function Handle:clear_writable() clear_hint(self, 'write'); return true end

function Handle:set_nonblocking(value)
  local ok, err = callback(self, 'set_nonblocking', value ~= false)
  if ok == nil and err and tostring(err):match('^unsupported_') then return true end
  return ok, err
end

function Handle:read(max)
  local a, b, c = callback(self, 'read', max)
  clear_hint(self, 'read')
  return a, b, c
end

function Handle:write(bytes)
  local a, b, c = callback(self, 'write', bytes)
  clear_hint(self, 'write')
  return a, b, c
end

function Handle:shutdown_read(reason)
  local ok, err = callback(self, 'shutdown_read', reason)
  if ok == nil and err and tostring(err):match('^unsupported_') then return true end
  return ok, err
end

function Handle:shutdown_write(reason)
  local ok, err = callback(self, 'shutdown_write', reason)
  if ok == nil and err and tostring(err):match('^unsupported_') then return true end
  return ok, err
end

function Handle:close(reason)
  if self.closed then return true end
  self.closed = true
  local ok, err = callback(self, 'close', reason)
  if ok == nil and err and tostring(err):match('^unsupported_') then
    self:shutdown_read(reason)
    self:shutdown_write(reason)
    return true
  end
  return ok, err
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
  if not fake_auto(self) then return end
  if fake_has_read_event(self) and not self.read_blocked then mark_hint(self, 'read') else clear_hint(self, 'read') end
end

local function fake_update_write_ready(self)
  if not fake_auto(self) then return end
  if self.write_blocked or self.write_error or self.closed then clear_hint(self, 'write') else mark_hint(self, 'write') end
end

function Handle.fake(opts)
  opts = opts or {}
  next_fake = next_fake + 1
  local key = opts.key or ('fake-handle-' .. tostring(next_fake))
  local self = Handle.new {
    name = opts.name or key,
    key = key,
    host = opts.host,
    readiness = opts.readiness,
    feed = opts.feed,
  }
  setmetatable(self, Fake)
  self.input = {}
  self.output = {}
  self.eof = false
  self.read_error = nil
  self.write_error = nil
  self.read_blocked = opts.read_blocked == true
  self.write_blocked = opts.write_blocked == true
  self.write_chunk_size = opts.write_chunk_size
  self.readiness_mode = opts.readiness_mode or opts.readiness or (opts.manual_readiness and 'manual' or 'auto')
  self.shutdown_read_reason = nil
  self.shutdown_write_reason = nil
  self.closed_reason = nil
  if opts.input then self:feed_read(opts.input) end
  if opts.eof then self:feed_eof() end
  if opts.read_error then self:feed_read_error(opts.read_error) end
  if opts.initial_writable ~= false then fake_update_write_ready(self) end
  return self
end

function Fake:bind_runtime(rt)
  Handle.bind_runtime(self, rt)
  fake_update_read_ready(self)
  fake_update_write_ready(self)
  return self
end

function Fake:feed_read(bytes)
  if type(bytes) ~= 'string' then error('fake handle feed_read expects bytes', 2) end
  if bytes ~= '' then self.input[#self.input + 1] = bytes end
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
  if self.read_blocked then clear_hint(self, 'read'); return nil, 'would_block' end
  if #self.input > 0 then
    local first = self.input[1]
    local take = math.min(#first, max)
    local out = string.sub(first, 1, take)
    local rest = string.sub(first, take + 1)
    if rest == '' then table.remove(self.input, 1) else self.input[1] = rest end
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
    return nil, Errors.EOF
  end
  fake_update_read_ready(self)
  return nil, 'would_block'
end

function Fake:write(bytes)
  if self.write_error then return nil, self.write_error end
  if self.write_blocked then clear_hint(self, 'write'); return nil, 'would_block' end
  if self.closed then return nil, Errors.CLOSED end
  local n = math.min(#bytes, self.write_chunk_size or #bytes)
  if n <= 0 then return 0 end
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


-- A mode-split handle composes a read handle and a write handle into the
-- duplex HostHandle shape expected by Stream.open_handle_op.  This is useful
-- for pipe pairs and later subprocess stdio: readiness and I/O remain delegated
-- to the true underlying end for each direction.
local Duplex = {}
Duplex.__index = Duplex
setmetatable(Duplex, { __index = Handle })

function Handle.duplex(read_handle, write_handle, opts)
  opts = opts or {}
  if type(read_handle) ~= 'table' or type(write_handle) ~= 'table' then error('Handle.duplex expects read and write handles', 2) end
  next_id = next_id + 1
  local self = {
    name = opts.name or ('duplex-handle-' .. tostring(next_id)),
    key = opts.key or { read = read_handle.readiness_key and read_handle:readiness_key() or read_handle.key,
                        write = write_handle.readiness_key and write_handle:readiness_key() or write_handle.key },
    read_handle = read_handle,
    write_handle = write_handle,
    host = opts.host or read_handle.host or write_handle.host,
    runtime = nil,
    stream = nil,
    _fibers_host_handle = true,
  }
  return setmetatable(self, Duplex)
end

function Duplex:is_handle() return true end
function Duplex:readiness_key() return self.key end

function Duplex:bind_runtime(rt)
  self.runtime = rt
  if self.read_handle and type(self.read_handle.bind_runtime) == 'function' then self.read_handle:bind_runtime(rt) end
  if self.write_handle and type(self.write_handle.bind_runtime) == 'function' then self.write_handle:bind_runtime(rt) end
  return self
end

function Duplex:attach_stream(stream)
  self.stream = stream
  if self.read_handle and type(self.read_handle.attach_stream) == 'function' then self.read_handle:attach_stream(stream) end
  if self.write_handle and type(self.write_handle.attach_stream) == 'function' then self.write_handle:attach_stream(stream) end
  return self
end

function Duplex:ready_op(mode)
  mode = normalise_mode(mode)
  if mode == 'write' then return self.write_handle:write_ready_op() end
  return self.read_handle:read_ready_op()
end
function Duplex:read_ready_op() return self:ready_op('read') end
function Duplex:write_ready_op() return self:ready_op('write') end
function Duplex:read(max) return self.read_handle:read(max) end
function Duplex:write(bytes) return self.write_handle:write(bytes) end
function Duplex:shutdown_read(reason) if type(self.read_handle.shutdown_read) == 'function' then return self.read_handle:shutdown_read(reason) end return true end
function Duplex:shutdown_write(reason) if type(self.write_handle.shutdown_write) == 'function' then return self.write_handle:shutdown_write(reason) end return true end
function Duplex:close(reason)
  if self.closed then return true end
  self.closed = true
  local ok1, err1 = true, nil
  local ok2, err2 = true, nil
  if self.read_handle and type(self.read_handle.close) == 'function' then ok1, err1 = self.read_handle:close(reason) end
  if self.write_handle and self.write_handle ~= self.read_handle and type(self.write_handle.close) == 'function' then ok2, err2 = self.write_handle:close(reason) end
  if not ok1 then return nil, err1 end
  if not ok2 then return nil, err2 end
  return true
end

Handle.Duplex = Duplex

Handle.Fake = Fake
return Handle
