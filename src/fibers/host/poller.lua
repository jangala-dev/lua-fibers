-- Runtime-owned indexed readiness poller.
--
-- The poller is a compact external resource.  Reactor registrations are armed
-- and disarmed by identity; one next_op contributes the complete host poller
-- interest without constructing an option branch per direction.  Complete host
-- families may update kernel registrations incrementally, while stateless hosts
-- can inspect the active snapshot.

local PollerQueue = require('fibers.host.poller_queue')
local Interest = require('fibers.external.interest')
local Runtime = require('fibers.runtime')
local UnsafeExternalMutation = require('fibers.internal.unsafe_external_mutation')

local Poller = {}
Poller.__index = Poller

local by_runtime = setmetatable({}, { __mode = 'k' })
local next_poller = 0

local function key_id(key)
  return type(key) .. ':' .. tostring(key)
end

local function normalise_mode(mode)
  if mode == 'wr' then
    mode = 'write'
  end
  if mode ~= 'read' and mode ~= 'write' then
    error('poller mode must be read or write', 3)
  end
  return mode
end

function Poller.new(runtime, opts)
  opts = opts or {}
  next_poller = next_poller + 1
  local id = 'host-poller-' .. tostring(next_poller)
  local self = setmetatable({
    runtime = runtime,
    name = opts.name or id,
    _fibers_id = id,
    registrations = {},
    by_key = {},
    generation = 0,
    changes = {},
    compacted_generation = 0,
    change_limit = opts.change_limit or 256,
    host_cursors = setmetatable({}, { __mode = 'k' }),
  }, Poller)
  self.ready = PollerQueue.new(id .. ':ready', {
    interest = function(_rt, queue, feed)
      return Interest.external(queue, 'poll', {
        external_kind = 'poller',
        poller = self,
        feed = feed,
      })
    end,
  })
  return self
end

function Poller.for_runtime(runtime, opts)
  runtime = runtime or Runtime.current()
  if not runtime then
    error('HostPoller.for_runtime requires a runtime', 2)
  end
  local poller = by_runtime[runtime]
  if not poller then
    poller = Poller.new(runtime, opts)
    by_runtime[runtime] = poller
    runtime.host_poller = poller
  end
  return poller
end

function Poller:_record(action, registration)
  self.generation = self.generation + 1
  self.changes[#self.changes + 1] = {
    sequence = self.generation,
    action = action,
    id = registration.id,
    generation = registration.generation,
    key = registration.key,
    mode = registration.mode,
  }
  if #self.changes > self.change_limit then
    self.changes = {}
    self.compacted_generation = self.generation
  end
end

function Poller:register(spec)
  if type(spec) ~= 'table' then
    error('poller registration expects a table', 2)
  end
  local id = assert(spec.id, 'poller registration requires id')
  if self.registrations[id] then
    error('duplicate poller registration ' .. tostring(id), 2)
  end
  local registration = {
    id = id,
    generation = assert(spec.generation, 'poller registration requires generation'),
    key = assert(spec.key, 'poller registration requires key'),
    mode = normalise_mode(spec.mode),
    armed = false,
    retired = false,
  }
  self.registrations[id] = registration
  local key = key_id(registration.key)
  local rec = self.by_key[key]
  if not rec then
    rec = {}
    self.by_key[key] = rec
  end
  rec[id] = registration
  return registration
end

function Poller:arm(id, generation)
  local registration = self.registrations[id]
  if not registration or registration.retired or registration.generation ~= generation then
    return false
  end
  if registration.armed then
    return true
  end
  registration.armed = true
  self:_record('arm', registration)
  return true
end

function Poller:disarm(id, generation)
  local registration = self.registrations[id]
  if not registration or registration.generation ~= generation then
    return false
  end
  if not registration.armed then
    return true
  end
  registration.armed = false
  self:_record('disarm', registration)
  return true
end

function Poller:retire(id, generation)
  local registration = self.registrations[id]
  if not registration or registration.generation ~= generation then
    return false
  end
  if registration.armed then
    registration.armed = false
    self:_record('disarm', registration)
  end
  registration.retired = true
  self:_record('retire', registration)
  self.registrations[id] = nil
  local key = key_id(registration.key)
  local rec = self.by_key[key]
  if rec then
    rec[id] = nil
    if next(rec) == nil then
      self.by_key[key] = nil
    end
  end
  return true
end

function Poller:hint(key, mode)
  mode = normalise_mode(mode)
  local rec = self.by_key[key_id(key)]
  if not rec then
    return false
  end
  local delivered = false
  for _, registration in pairs(rec) do
    if registration.armed and registration.mode == mode then
      registration.armed = false
      self:_record('disarm', registration)
      UnsafeExternalMutation.deliver(
        self.ready,
        registration.id,
        registration.generation,
        registration.mode,
        registration.key
      )
      delivered = true
    end
  end
  return delivered
end

function Poller:_host_delivered(registration)
  local current = self.registrations[registration.id]
  if not current or current.generation ~= registration.generation or not current.armed or current.retired then
    return false
  end
  current.armed = false
  self:_record('disarm', current)
  return true
end

function Poller:_host_changes(host)
  local cursor = self.host_cursors[host]
  local out = {}
  if cursor == nil or cursor < self.compacted_generation then
    out[1] = { action = 'reset', sequence = self.generation }
    for _, registration in pairs(self.registrations) do
      if registration.armed and not registration.retired then
        out[#out + 1] = {
          action = 'arm',
          sequence = self.generation,
          id = registration.id,
          generation = registration.generation,
          key = registration.key,
          mode = registration.mode,
        }
      end
    end
  else
    for i = 1, #self.changes do
      local change = self.changes[i]
      if change.sequence > cursor then
        out[#out + 1] = change
      end
    end
  end
  self.host_cursors[host] = self.generation
  local all_current = true
  for _, seen in pairs(self.host_cursors) do
    if seen < self.generation then
      all_current = false
      break
    end
  end
  if all_current then
    self.changes = {}
    self.compacted_generation = self.generation
  end
  return out
end

function Poller:_host_active()
  local out = {}
  for _, registration in pairs(self.registrations) do
    if registration.armed and not registration.retired then
      out[#out + 1] = registration
    end
  end
  return out
end

function Poller:next_op()
  return self.ready:next_op()
end

function Poller:registration_count()
  local n = 0
  for _ in pairs(self.registrations) do
    n = n + 1
  end
  return n
end

return Poller
