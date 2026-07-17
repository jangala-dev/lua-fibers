-- Capability-shaped streams built from unidirectional byte flows.
--
-- Flow is the public transactional byte engine. A Stream may contain a read
-- Flow, a write Flow, or both. Host directions register with the runtime-owned
-- indexed HostPoller and shared HostReactor; no task is allocated per direction.

local Op = require('fibers.op')
local Reactor = require('fibers.host.reactor')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.internal.settlement')
local Flow = require('fibers.flow')
local Runtime = require('fibers.runtime')

local Stream = {}
local Duplex = {}
Duplex.__index = Duplex
local HostStream = {}
HostStream.__index = HostStream

local next_duplex = 0
local next_host_stream = 0

local function validate_options(opts, allowed, label)
  for key in pairs(opts or {}) do
    if not allowed[key] then
      error((label or 'options') .. ' does not accept ' .. tostring(key), 3)
    end
  end
end

local function region_of(x)
  if x and x._fibers_scope and type(x.raw_region) == 'function' then
    return x:raw_region()
  end
  if x and type(x.admit_op) == 'function' and type(x.move_op) == 'function' then
    return x
  end
  return nil
end

local function duplex(opts)
  opts = opts or {}
  next_duplex = next_duplex + 1
  local name = opts.name or ('duplex-' .. tostring(next_duplex))
  local d = Ownership.handle(name, {
    kind = opts.kind or 'duplex_stream',
    mode = opts.mode or 'memory',
    read_flow = opts.read_flow,
    write_flow = opts.write_flow,
    backend = opts.backend,
    reactor = opts.reactor,
    read_registration = nil,
    write_registration = nil,
    _reactor_live = 0,
    _backend_closed = false,
    _fibers_kind_name = opts.kind or 'duplex_stream',
    _fibers_obligation_kind = opts.kind or 'duplex_stream',
    settle = opts.settle or Settlement.stream(),
    settle_name = opts.settle_name or 'stream',
  })
  setmetatable(d, opts.metatable or Duplex)
  return d
end

function Duplex:is_readable()
  return self.read_flow ~= nil
end
function Duplex:is_writable()
  return self.write_flow ~= nil
end
function Duplex:is_duplex()
  return self.read_flow ~= nil and self.write_flow ~= nil
end
function Duplex:reader()
  return self.read_flow and self.read_flow:outlet() or nil
end
function Duplex:writer()
  return self.write_flow and self.write_flow:inlet() or nil
end
local function require_reader(self, level)
  local reader = self:reader()
  if not reader then
    error('stream is not readable', level or 3)
  end
  return reader
end
local function require_writer(self, level)
  local writer = self:writer()
  if not writer then
    error('stream is not writable', level or 3)
  end
  return writer
end
function Duplex:read_some_op(n)
  return require_reader(self):read_some_op(n)
end

function Duplex:read_exactly_op(n)
  return require_reader(self):read_exactly_op(n)
end

function Duplex:read_until_op(separator, opts)
  return require_reader(self):read_until_op(separator, opts)
end

function Duplex:read_line_op(opts)
  return require_reader(self):read_line_op(opts)
end

function Duplex:read_all_op(opts)
  return require_reader(self):read_all_op(opts)
end

-- Lua-file-style migration helper.  It still constructs an inert option.
function Duplex:read_op(spec, opts)
  if type(spec) == 'number' then
    return self:read_some_op(spec)
  end
  if spec == '*l' then
    opts = opts or {}
    opts.keep_terminator = false
    return self:read_line_op(opts)
  end
  if spec == '*L' then
    opts = opts or {}
    opts.keep_terminator = true
    return self:read_line_op(opts)
  end
  if spec == '*a' then
    return self:read_all_op(opts)
  end
  error("stream read_op expects a byte count, '*l', '*L' or '*a'", 2)
end

local function join_write_parts(...)
  local n = select('#', ...)
  if n == 0 then
    return ''
  end
  local parts = {}
  for i = 1, n do
    local part = select(i, ...)
    if type(part) ~= 'string' then
      error('stream write expects string arguments', 3)
    end
    parts[i] = part
  end
  return table.concat(parts)
end

function Duplex:write_op(...)
  return require_writer(self):write_op(join_write_parts(...))
end

function Duplex:write_some_op(bytes)
  return require_writer(self):write_some_op(bytes)
end

function Duplex:flush_op()
  return require_writer(self):flush_op()
end

function Duplex:inspect_op()
  local options = {}
  if self.read_flow then
    options[#options + 1] = { 'read', self.read_flow:inspect_op() }
  end
  if self.write_flow then
    options[#options + 1] = { 'write', self.write_flow:inspect_op() }
  end
  return Op.named_all(options):map(function(parts)
    return {
      stream = self,
      read = parts.read,
      write = parts.write,
      mode = self.mode,
      readable = self:is_readable(),
      writable = self:is_writable(),
    }
  end)
end

local function wait_after_commit(self, request, before_closed)
  return request:wrap(function()
    local rt = Runtime.current()
    if not rt then
      error('Stream closure requires a current runtime', 2)
    end
    if before_closed then
      local ok, err = before_closed(rt)
      if not ok then
        return nil, err
      end
    end
    return rt:_perform_current(self:closed_op(), nil, true)
  end)
end

function Duplex:shutdown_read_op(reason)
  if not self.read_flow then
    return Op.always(true)
  end
  local options = { self.read_flow:outlet():close_op(reason) }
  if self.read_registration then
    options[#options + 1] = self.read_registration:retire_op(reason, 'immediate')
  end
  return Op.tensor(options):map(function()
    return true
  end)
end

function Duplex:shutdown_write_op(reason)
  if not self.write_flow then
    return Op.always(true)
  end
  local options = { self.write_flow:inlet():close_op(reason) }
  if self.write_registration then
    options[#options + 1] = self.write_registration:retire_op(reason, 'drain')
  end
  return Op.tensor(options):map(function()
    return true
  end)
end

function Duplex:abort_write_op(reason)
  if not self.write_flow then
    return Op.always(true)
  end
  local options = { self.write_flow:abort_op(reason) }
  if self.write_registration then
    options[#options + 1] = self.write_registration:retire_op(reason, 'abort')
  end
  return Op.tensor(options):map(function()
    return true
  end)
end

local function close_request(self, reason, abort_write)
  local options = {}
  if self.read_flow then
    options[#options + 1] = self:shutdown_read_op(reason)
  end
  if self.write_flow then
    options[#options + 1] = abort_write and self:abort_write_op(reason) or self:shutdown_write_op(reason)
  end
  if #options == 0 then
    return Op.always(true)
  end
  return Op.tensor(options):map(function()
    return true
  end)
end

function Duplex:close_op(reason)
  local request = close_request(self, reason, false)
  return wait_after_commit(self, request, function(rt)
    if self.write_flow then
      return rt:_perform_current(self.write_flow:inlet():flush_op(), nil, true)
    end
    return true
  end)
end

function Duplex:abort_op(reason)
  return wait_after_commit(self, close_request(self, reason, true))
end

function Duplex:closed_op()
  local options = {}
  if self.read_flow then
    options[#options + 1] = self.read_flow:outlet():closed_op()
  end
  if self.write_flow then
    options[#options + 1] = self.write_flow:inlet():closed_op()
  end
  if self.read_registration then
    options[#options + 1] = self.read_registration:retired_op()
  end
  if self.write_registration then
    options[#options + 1] = self.write_registration:retired_op()
  end
  return Op.all(options):map(function()
    if self._close_error then
      return nil, self._close_error
    end
    return true
  end)
end

local function host_stream(opts)
  opts = opts or {}
  next_host_stream = next_host_stream + 1
  local name = opts.name or ('host-stream-' .. tostring(next_host_stream))
  local readable = opts.read ~= false
  local writable = opts.write ~= false
  if not readable and not writable then
    error('host stream requires a readable or writable direction', 3)
  end
  local rx = readable
      and Flow.new({
        name = name .. ':rx',
        capacity = opts.read_capacity or opts.capacity,
      })
    or nil
  local tx = writable
      and Flow.new({
        name = name .. ':tx',
        capacity = opts.write_capacity or opts.capacity,
      })
    or nil
  local h = duplex({
    name = name,
    kind = 'host_stream',
    mode = readable and writable and 'duplex' or (readable and 'reader' or 'writer'),
    read_flow = rx,
    write_flow = tx,
    backend = opts.backend,
    reactor = opts.reactor,
    metatable = HostStream,
  })
  h.read_chunk_size = opts.read_chunk_size or opts.chunk_size or 4096
  h.write_chunk_size = opts.write_chunk_size or opts.chunk_size or 4096
  h._close_error = nil
  return h
end

function Stream.memory_pair(opts)
  opts = opts or {}
  validate_options(opts, { name = true, capacity = true }, 'Stream.memory_pair options')
  local name = opts.name or 'memory-flow'
  local flow_ab = Flow.new({ name = name .. ':a->b', capacity = opts.capacity })
  local flow_ba = Flow.new({ name = name .. ':b->a', capacity = opts.capacity })
  local a = duplex({ name = name .. ':a', read_flow = flow_ba, write_flow = flow_ab, mode = 'memory' })
  local b = duplex({ name = name .. ':b', read_flow = flow_ab, write_flow = flow_ba, mode = 'memory' })
  return a, b
end

local function open_in_op(owner, backend, opts)
  opts = opts or {}
  validate_options(opts, {
    owner = true,
    name = true,
    read = true,
    write = true,
    read_capacity = true,
    write_capacity = true,
    read_chunk_size = true,
    write_chunk_size = true,
  }, 'Stream.open_op options')
  local region = region_of(owner)
  if not region or type(region.admit_op) ~= 'function' then
    error('Stream.open_op opts.owner must be a Scope or Region', 3)
  end
  if type(backend) ~= 'table' then
    error('Stream.open_op expects a backend table', 3)
  end
  if type(opts.read) ~= 'boolean' or type(opts.write) ~= 'boolean' then
    error('Stream.open_op requires explicit boolean opts.read and opts.write', 3)
  end
  local readable = opts.read
  local writable = opts.write
  if not readable and not writable then
    error('Stream.open_op requires at least one enabled direction', 3)
  end
  if readable and (type(backend.read) ~= 'function' or backend.read_supported == false) then
    error('readable Stream backend requires read(max)', 3)
  end
  if writable and (type(backend.write) ~= 'function' or backend.write_supported == false) then
    error('writable Stream backend requires write(bytes)', 3)
  end
  if type(backend.close) ~= 'function' or backend.close_supported == false then
    error('Stream backend requires close(reason)', 3)
  end
  local name = opts.name or backend.name or 'host-stream'
  local rt = Runtime.current()
  if not rt then
    error('Stream.open_op requires a current runtime', 3)
  end
  local reactor = Reactor.for_runtime(rt)
  local hs = host_stream({
    name = name,
    backend = backend,
    reactor = reactor,
    read = readable,
    write = writable,
    read_capacity = opts.read_capacity,
    write_capacity = opts.write_capacity,
    read_chunk_size = opts.read_chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or 4096,
  })
  local owned_children = {}
  local registrations = {}
  if hs.read_flow then
    hs.read_registration = reactor:direction({
      name = name .. ':read',
      mode = 'read',
      stream = hs,
      flow = hs.read_flow,
      backend = backend,
      chunk_size = hs.read_chunk_size,
    })
    owned_children[#owned_children + 1] = Owned.item(
      hs.read_flow,
      hs.read_flow._fibers_settle or Settlement.flow(),
      { role = 'read_flow', settle_name = 'flow' }
    )
    owned_children[#owned_children + 1] = Owned.inert(hs:reader(), { role = 'reader' })
    owned_children[#owned_children + 1] = Owned.inert(hs.read_registration, { role = 'read_reaction' })
    registrations[#registrations + 1] = { 'read_registration', hs.read_registration:register_op() }
  end
  if hs.write_flow then
    hs.write_registration = reactor:direction({
      name = name .. ':write',
      mode = 'write',
      stream = hs,
      flow = hs.write_flow,
      backend = backend,
      chunk_size = hs.write_chunk_size,
    })
    owned_children[#owned_children + 1] = Owned.item(
      hs.write_flow,
      hs.write_flow._fibers_settle or Settlement.flow(),
      { role = 'write_flow', settle_name = 'flow' }
    )
    owned_children[#owned_children + 1] = Owned.inert(hs:writer(), { role = 'writer' })
    owned_children[#owned_children + 1] = Owned.inert(hs.write_registration, { role = 'write_reaction' })
    registrations[#registrations + 1] = { 'write_registration', hs.write_registration:register_op() }
  end
  hs._reactor_live = #registrations
  local start_op = Op.named_all(registrations):map(function()
    return hs
  end)
  local owned = Owned.tree(
    hs,
    hs._fibers_settle or Settlement.stream(),
    owned_children,
    { role = 'stream', settle_name = 'stream' }
  )
  local admit_op = owner._fibers_scope and type(owner.admit_op) == 'function' and owner:admit_op(owned)
    or region:admit_op(owned)
  return admit_op:and_then(function()
    return start_op
  end)
end

function Stream.open_op(backend, opts)
  opts = opts or {}
  local owner = opts.owner or (Runtime.current_scope and Runtime.current_scope())
  if not owner then
    error('Stream.open_op requires opts.owner or a current Scope', 2)
  end
  return open_in_op(owner, backend, opts)
end

HostStream.is_readable = Duplex.is_readable
HostStream.is_writable = Duplex.is_writable
HostStream.is_duplex = Duplex.is_duplex
HostStream.reader = Duplex.reader
HostStream.writer = Duplex.writer
HostStream.read_some_op = Duplex.read_some_op
HostStream.read_exactly_op = Duplex.read_exactly_op
HostStream.read_until_op = Duplex.read_until_op
HostStream.read_line_op = Duplex.read_line_op
HostStream.read_all_op = Duplex.read_all_op
HostStream.read_op = Duplex.read_op
HostStream.write_op = Duplex.write_op
HostStream.write_some_op = Duplex.write_some_op
HostStream.flush_op = Duplex.flush_op
HostStream.inspect_op = Duplex.inspect_op
HostStream.shutdown_read_op = Duplex.shutdown_read_op
HostStream.shutdown_write_op = Duplex.shutdown_write_op
HostStream.abort_write_op = Duplex.abort_write_op
HostStream.close_op = Duplex.close_op
HostStream.abort_op = Duplex.abort_op
HostStream.closed_op = Duplex.closed_op

-- Select one complete line from a named collection of Streams.
function Stream.merge_lines_op(streams, opts)
  local entries = {}
  for name, stream in pairs(streams or {}) do
    entries[#entries + 1] = {
      name,
      stream:read_line_op(opts):map(function(line, err)
        return name, line, err
      end),
    }
  end
  if #entries == 0 then
    return Op.never()
  end
  return Op.named_choice(entries):map(function(_selected, source, line, err)
    return source, line, err
  end)
end

return Stream
