-- Deterministic HostHandle test double.

local Errors = require('fibers.resource.flow.errors')
local Handle = require('fibers.io.handle')
local HostError = require('fibers.io.error')
local IOAudit = require('fibers.diagnostics.io')

local Fake = {}
Fake.__index = Fake
setmetatable(Fake, { __index = Handle })
local serial = 0

local function automatic(self)
  return self.readiness_mode ~= 'manual'
end
local function read_event(self)
  return #self.input > 0 or self.eof or self.read_error
end
local function read_ready(self)
  if not automatic(self) then
    return
  end
  if read_event(self) and not self.read_blocked then
    self:mark_readable()
  else
    self:clear_readable()
  end
end
local function write_ready(self)
  if not automatic(self) then
    return
  end
  if self.write_blocked or self.closed then
    self:clear_writable()
  else
    self:mark_writable()
  end
end
local function clear_manual(self, mode)
  if not automatic(self) then
    if mode == 'read' then
      self:clear_readable()
    else
      self:clear_writable()
    end
  end
end

function Fake.new(opts)
  opts = opts or {}
  serial = serial + 1
  local key = opts.key or ('fake-handle-' .. serial)
  local self = Handle.new({
    label = opts.label or key,
    key = key,
    host = opts.host,
    readiness = type(opts.readiness) == 'table' and opts.readiness or nil,
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
  self.input, self.output = {}, {}
  self.eof = false
  self.read_blocked = opts.read_blocked == true
  self.write_blocked = opts.write_blocked == true
  self.write_chunk_size = opts.write_chunk_size
  self.readiness_mode = opts.readiness_mode
    or opts.readiness
    or (opts.manual_readiness and 'manual' or 'auto')
  self.close_count = 0
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
  if opts.initial_writable ~= false then
    write_ready(self)
  end
  return self
end

function Fake:bind_runtime(runtime)
  Handle.bind_runtime(self, runtime)
  read_ready(self)
  write_ready(self)
  return self
end
function Fake:feed_read(bytes)
  if type(bytes) ~= 'string' then
    error('fake handle feed_read expects bytes', 2)
  end
  if bytes ~= '' then
    self.input[#self.input + 1] = bytes
  end
  read_ready(self)
end
function Fake:feed_eof()
  self.eof = true
  read_ready(self)
end
function Fake:feed_read_error(err)
  self.read_error = err or Errors.READ_ERROR
  read_ready(self)
end
function Fake:block_reads()
  self.read_blocked = true
  read_ready(self)
end
function Fake:unblock_reads()
  self.read_blocked = false
  read_ready(self)
end
function Fake:block_writes()
  self.write_blocked = true
  if automatic(self) then
    write_ready(self)
  else
    self:clear_writable()
  end
end
function Fake:unblock_writes()
  self.write_blocked = false
  if automatic(self) then
    write_ready(self)
  else
    self:mark_writable()
  end
end
function Fake:set_write_chunk_size(n)
  self.write_chunk_size = n
end
function Fake:fail_writes(err)
  self.write_error = err or Errors.WRITE_ERROR
  write_ready(self)
end

function Fake:read(max)
  max = max or 4096
  if self.read_blocked then
    clear_manual(self, 'read')
    return nil, HostError.would_block('handle', 'read', { handle = (self.label and self:label() or self._fibers_id) })
  end
  if #self.input > 0 then
    local first = self.input[1]
    local count = math.min(#first, max)
    local out, rest = first:sub(1, count), first:sub(count + 1)
    if rest == '' then
      table.remove(self.input, 1)
    else
      self.input[1] = rest
    end
    read_ready(self)
    if #self.input == 0 and not self.eof and not self.read_error then
      clear_manual(self, 'read')
    end
    return out
  end
  if self.read_error then
    local err = self.read_error
    self.read_error = nil
    read_ready(self)
    clear_manual(self, 'read')
    return nil, err
  end
  if self.eof then
    self.eof = false
    read_ready(self)
    clear_manual(self, 'read')
    return nil, HostError.eof('handle', 'read', { handle = (self.label and self:label() or self._fibers_id) })
  end
  read_ready(self)
  clear_manual(self, 'read')
  return nil, HostError.would_block('handle', 'read', { handle = (self.label and self:label() or self._fibers_id) })
end

function Fake:write(bytes)
  if self.write_error then
    return nil, self.write_error
  end
  if self.write_blocked then
    self:clear_writable()
    return nil, HostError.would_block('handle', 'write', { handle = (self.label and self:label() or self._fibers_id) })
  end
  if self.closed then
    return nil, HostError.closed('handle', 'write', { handle = (self.label and self:label() or self._fibers_id) })
  end
  local count = math.min(#bytes, self.write_chunk_size or #bytes)
  if count <= 0 then
    return 0
  end
  self.output[#self.output + 1] = bytes:sub(1, count)
  write_ready(self)
  return count
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
  if self.closed then
    return true
  end
  IOAudit.closing(self, reason)
  self.close_count = self.close_count + 1
  self.closed, self.closed_reason = true, reason or true
  self:shutdown_read(reason)
  self:shutdown_write(reason)
  read_ready(self)
  write_ready(self)
  IOAudit.closed(self, true, nil, reason)
  return true
end

return Fake
