-- Fake host stream backend for tests and examples.
--
-- It simulates non-blocking host I/O without depending on OS files, sockets or
-- polling.  Readiness may be automatic or manual:
--   auto   : host state changes mark/clear readiness hints immediately
--   manual : tests/examples explicitly deliver readiness hints
--
-- Readiness remains only a hint.  EOF and errors are reported by read/write.

local ReadinessBackend = require('fibers.stream.backend.readiness')
local UnsafeExternalMutation = require('fibers.internal.unsafe_external_mutation')

local Errors = require('fibers.internal.flow.errors')

local Fake = {}
Fake.__index = Fake

local next_id = 0

local function note_change(self) end

local function remember_ready(self, mode, value)
  value = value == nil and true or value
  if self.readiness then
    UnsafeExternalMutation.deliver(self.readiness, mode, value)
    note_change(self)
    return self.readiness
  end
  self._pending_ready = self._pending_ready or {}
  self._pending_ready[mode] = value
end

local function remember_clear(self, mode)
  if self.readiness then
    UnsafeExternalMutation.clear(self.readiness, mode)
    note_change(self)
    return self.readiness
  end
  self._pending_clear = self._pending_clear or {}
  self._pending_clear[mode] = true
end

local function apply_pending(self)
  if not self.feed then
    return
  end
  for mode, value in pairs(self._pending_ready or {}) do
    remember_ready(self, mode, value)
  end
  self._pending_ready = {}
  for mode in pairs(self._pending_clear or {}) do
    remember_clear(self, mode)
  end
  self._pending_clear = {}
end

local function has_read_event(self)
  return #(self.input or {}) > 0 or self.eof or self.read_error
end

local function auto(self)
  return self.readiness_mode ~= 'manual'
end

local function update_read_ready(self)
  if not auto(self) then
    return
  end
  if has_read_event(self) and not self.read_blocked then
    remember_ready(self, 'read')
  else
    remember_clear(self, 'read')
  end
end

local function update_write_ready(self)
  if not auto(self) then
    return
  end
  if self.write_blocked then
    remember_clear(self, 'write')
  else
    remember_ready(self, 'write')
  end
end

local function maybe_clear_manual(self, mode)
  if not auto(self) then
    remember_clear(self, mode)
  end
end

function Fake.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local name = opts.name or ('fake-backend-' .. tostring(next_id))
  local self = setmetatable({
    name = name,
    key = opts.key or (name .. ':key'),
    readiness_mode = opts.readiness or (opts.manual_readiness and 'manual' or 'auto'),
    input = {},
    output = {},
    eof = false,
    read_error = nil,
    write_error = nil,
    read_blocked = opts.read_blocked == true,
    write_blocked = opts.write_blocked == true,
    write_chunk_size = opts.write_chunk_size,
    shutdown_read_reason = nil,
    shutdown_write_reason = nil,
    closed_reason = nil,
    _pending_ready = {},
    _pending_clear = {},
  }, Fake)
  self._backend = ReadinessBackend.new({
    name = self.name,
    key = self.key,
    read = function(_, max)
      return self:read(max)
    end,
    write = function(_, bytes)
      return self:write(bytes)
    end,
    shutdown_read = function(_, reason)
      return self:shutdown_read(reason)
    end,
    shutdown_write = function(_, reason)
      return self:shutdown_write(reason)
    end,
    close = function(_, reason)
      return self:close(reason)
    end,
  })
  if opts.input then
    self:feed_read(opts.input)
  end
  if opts.eof then
    self:feed_eof()
  end
  if opts.read_error then
    self:feed_read_error(opts.read_error)
  end
  if opts.initial_readable then
    self:mark_readable()
  end
  if opts.initial_writable ~= false and not self.write_blocked then
    self:mark_writable()
  end
  return self
end

function Fake:bind_runtime(rt)
  self._backend:bind_runtime(rt)
  self.runtime = rt
  self.readiness = self._backend.readiness
  self.feed = self._backend.feed
  apply_pending(self)
  update_read_ready(self)
  update_write_ready(self)
  return self
end

function Fake:attach_stream(stream)
  self.stream = stream
  return self._backend:attach_stream(stream)
end

function Fake:read_ready_op()
  return self._backend:read_ready_op()
end
function Fake:write_ready_op()
  return self._backend:write_ready_op()
end

function Fake:mark_readable()
  return remember_ready(self, 'read')
end
function Fake:mark_writable()
  return remember_ready(self, 'write')
end
function Fake:clear_readable()
  return remember_clear(self, 'read')
end
function Fake:clear_writable()
  return remember_clear(self, 'write')
end

function Fake:feed_read(bytes)
  if type(bytes) ~= 'string' then
    error('FakeBackend:feed_read expects bytes', 2)
  end
  if bytes ~= '' then
    self.input[#self.input + 1] = bytes
  end
  update_read_ready(self)
end

function Fake:feed_eof()
  self.eof = true
  update_read_ready(self)
end

function Fake:feed_read_error(err)
  self.read_error = err or Errors.READ_ERROR
  update_read_ready(self)
end

function Fake:read(max)
  max = max or 4096
  if self.read_blocked then
    return nil, 'would_block'
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
    update_read_ready(self)
    if #self.input == 0 and not self.eof and not self.read_error then
      maybe_clear_manual(self, 'read')
    end
    return out
  end
  if self.read_error then
    local err = self.read_error
    self.read_error = nil
    update_read_ready(self)
    maybe_clear_manual(self, 'read')
    return nil, err
  end
  if self.eof then
    self.eof = false
    update_read_ready(self)
    maybe_clear_manual(self, 'read')
    return nil, Errors.EOF
  end
  update_read_ready(self)
  maybe_clear_manual(self, 'read')
  return nil, 'would_block'
end

function Fake:block_reads()
  self.read_blocked = true
  update_read_ready(self)
end

function Fake:unblock_reads()
  self.read_blocked = false
  update_read_ready(self)
end

function Fake:block_writes()
  self.write_blocked = true
  if auto(self) then
    update_write_ready(self)
  else
    self:clear_writable()
  end
end

function Fake:unblock_writes()
  self.write_blocked = false
  if auto(self) then
    update_write_ready(self)
  else
    self:mark_writable()
  end
end

function Fake:set_write_chunk_size(n)
  self.write_chunk_size = n
end

function Fake:fail_writes(err)
  self.write_error = err or Errors.WRITE_ERROR
  update_write_ready(self)
end

function Fake:write(bytes)
  if self.write_error then
    return nil, self.write_error
  end
  if self.write_blocked then
    maybe_clear_manual(self, 'write')
    return nil, 'would_block'
  end
  local n = math.min(#bytes, self.write_chunk_size or #bytes)
  if n <= 0 then
    return 0
  end
  self.output[#self.output + 1] = string.sub(bytes, 1, n)
  return n
end

function Fake:written()
  return table.concat(self.output)
end

function Fake:shutdown_read(reason)
  self.shutdown_read_reason = reason or true
  update_read_ready(self)
  return true
end

function Fake:shutdown_write(reason)
  self.shutdown_write_reason = reason or true
  update_write_ready(self)
  return true
end

function Fake:close(reason)
  self.closed_reason = reason or true
  self:shutdown_read(reason)
  self:shutdown_write(reason)
  return true
end

return Fake
