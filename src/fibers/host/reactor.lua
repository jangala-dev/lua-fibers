-- Runtime-owned executor for readiness-driven host reactions.
--
-- The production reactor is indexed rather than algebraically enumerated.  A
-- compact HostPoller option yields ready registration identities; committed
-- Flow-change effects enqueue demand changes.  The reactor performs one bounded
-- authoritative host call for each ready ticket.  No host call occurs during
-- option search.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Effect = require('fibers.effect')
local EventQueue = require('fibers.resource.event_queue')
local Signal = require('fibers.resource.signal')
local Interest = require('fibers.host.external').Interest
local ExternalFeed = require('fibers.host.external').Feed
local UnsafeExternalMutation = require('fibers.host.unsafe_external_mutation')
local Errors = require('fibers.resource.flow.errors')
local HostError = require('fibers.host.error')
local Region = require('fibers.region')
local IOAudit = require('fibers.diagnostics.io')

local Reactor = {}
Reactor.__index = Reactor
local Entry = {}
Entry.__index = Entry

local next_reactor = 0
local next_entry = 0

local function optional_shutdown(handle, name, reason)
  local ok, err = handle[name](handle, reason)
  if ok == nil and HostError.is_unsupported(err) then
    return true
  end
  return ok, err
end

local function handle_key(handle, mode)
  local key = handle:readiness_key()
  if type(key) == 'table' and (key.read ~= nil or key.write ~= nil) then
    return key[mode]
  end
  return key
end

local function key_id(key)
  return type(key) .. ':' .. tostring(key)
end

local function handle_hint_ready(entry)
  local readiness = entry.handle and entry.handle.readiness
  local state = readiness and readiness._location and readiness._location.value
  return not not (state and state[entry.mode])
end

local function masked_perform(rt, option)
  return rt:_perform_current(option, nil, true)
end

local ControlKind
local function control_key(payload)
  return payload.reactor._fibers_id .. ':' .. payload.entry._fibers_id
end

ControlKind = Effect.kind({
  name = 'host_reactor_control',
  key = control_key,
  merge = function(a, b)
    if a.action == b.action then
      return a
    end
    return nil,
      {
        kind = 'effect_conflict',
        message = 'reactor registration and retirement cannot commit together',
      }
  end,
  prepare = function(rt, payload)
    if payload.reactor.runtime ~= rt then
      return nil, 'reactor belongs to another runtime'
    end
    if payload.entry.reactor ~= payload.reactor then
      return nil, 'reactor entry mismatch'
    end
    return {
      kind = ControlKind,
      key = control_key(payload),
      payload = payload,
      discharge = function(discharge_rt, prepared)
        local p = prepared.payload
        if p.action == 'register' then
          p.reactor:_register_committed(discharge_rt, p.entry)
        elseif p.action == 'retire' then
          p.reactor:_request_retire_committed(discharge_rt, p.entry, p.reason, p.mode)
        else
          error('unknown reactor control action ' .. tostring(p.action), 2)
        end
      end,
    }
  end,
})

local function control_effect(reactor, entry, action, reason, mode)
  return Effect.of(ControlKind, {
    reactor = reactor,
    entry = entry,
    action = action,
    reason = reason,
    mode = mode,
  })
end

function Entry.new(reactor, spec)
  spec = spec or {}
  next_entry = next_entry + 1
  local id = 'reaction-' .. tostring(next_entry)
  local key = handle_key(spec.handle, spec.mode)
  if key == nil then
    error('reactor-backed direction requires a readiness key', 3)
  end
  local entry = Region.handle(spec.name or id, {
    kind = 'host_reaction',
    mode = spec.mode,
    stream = spec.stream,
    flow = spec.flow,
    handle = spec.handle,
    reactor = reactor,
    chunk_size = spec.chunk_size or 4096,
    generation = spec.generation or next_entry,
    key = key,
    _fibers_id = id,
    id = id,
    armed = false,
  })
  setmetatable(entry, Entry)
  entry._fibers_id = id
  entry.retired_signal = Signal.new((spec.name or id) .. ':retired')
  entry.registered = false
  entry.retired = false
  entry.closing = false
  entry.retire_mode = nil
  entry.close_reason = nil
  entry.retire_error = nil
  entry.lease = nil
  entry.demand_queued = false
  entry.service_count = 0
  entry.would_block_count = 0
  entry.last_service_sequence = nil
  IOAudit.created(entry, { kind = 'reactor_registration' })
  return entry
end

function Entry:register_op()
  return Op.emit(control_effect(self.reactor, self, 'register')):map(function()
    return self
  end)
end

function Entry:retire_op(reason, mode)
  if self.retired then
    return Op.always(self.retire_error == nil, self.retire_error)
  end
  return Op.emit(control_effect(self.reactor, self, 'retire', reason, mode)):map(function()
    return true
  end)
end

function Entry:retired_op()
  if self.retired then
    return Op.always(self.retire_error == nil, self.retire_error)
  end
  return self.retired_signal:wait_op()
end

function Reactor.new(runtime, opts)
  opts = opts or {}
  next_reactor = next_reactor + 1
  local id = 'host-reactor-' .. tostring(next_reactor)
  local self = setmetatable({
    runtime = runtime,
    name = opts.name or id,
    _fibers_id = id,
    entries = {},
    by_key = {},
    flow_entries = setmetatable({}, { __mode = 'k' }),
    running = false,
    control = EventQueue.new(id .. ':control'),
    read_quantum = opts.read_quantum or 64 * 1024,
    write_quantum = opts.write_quantum or 64 * 1024,
    control_quantum = opts.control_quantum or 64,
    service_count = 0,
  }, Reactor)
  self.ready = EventQueue.new(id .. ':ready', {
    interest = function(_runtime, queue, feed)
      return Interest.external(queue, 'poll', {
        external_kind = 'poller',
        poller = self,
        feed = feed,
      })
    end,
  })
  return self
end

function Reactor.for_runtime(runtime, opts)
  runtime = runtime or Runtime.current()
  if not runtime then
    error('HostReactor.for_runtime requires a runtime', 2)
  end
  local reactor = runtime.host_reactor
  if not reactor then
    reactor = Reactor.new(runtime, opts)
    runtime.host_reactor = reactor
  end
  return reactor
end

function Reactor:direction(spec)
  spec = spec or {}
  spec.chunk_size = spec.chunk_size or (spec.mode == 'read' and self.read_quantum or self.write_quantum)
  return Entry.new(self, spec)
end

function Reactor:_notify(kind, entry, reason, mode)
  UnsafeExternalMutation.deliver(self.control, kind, entry, reason, mode)
end

function Reactor:_notify_demand(entry)
  if entry.retired or entry.demand_queued then
    return
  end
  entry.demand_queued = true
  self:_notify('demand', entry)
end

function Reactor:_notify_flow_changed(flow)
  local entries = self.flow_entries[flow]
  if not entries then
    return false
  end
  for _, entry in pairs(entries) do
    self:_notify_demand(entry)
  end
  return true
end

function Reactor:_ensure_running(rt)
  if self.running then
    return
  end
  self.running = true
  rt:_spawn_committed(function()
    return self:_run(rt)
  end, self.name, nil)
end

function Reactor:_attach_handle(rt, entry)
  local handle = entry.handle
  local stream = entry.stream
  if stream and stream._reactor_handle_attached then
    return
  end
  handle:attach_stream(stream)
  handle:bind_runtime(rt)
  if stream then
    stream._reactor_handle_attached = true
  end
end

function Reactor:_register_committed(rt, entry)
  if entry.retired then
    error('cannot register a retired reactor entry', 2)
  end
  if entry.registered then
    return entry
  end
  self:_attach_handle(rt, entry)
  entry.registered = true
  self.entries[entry._fibers_id] = entry
  IOAudit.register(entry, rt, { mode = entry.mode, key = entry.key })
  local key = key_id(entry.key)
  local registrations = self.by_key[key]
  if not registrations then
    registrations = {}
    self.by_key[key] = registrations
  end
  registrations[entry.id] = entry
  local flow_entries = self.flow_entries[entry.flow]
  if not flow_entries then
    flow_entries = {}
    self.flow_entries[entry.flow] = flow_entries
  end
  flow_entries[entry._fibers_id] = entry
  self:_ensure_running(rt)
  self:_notify_demand(entry)
  return entry
end

function Reactor:_request_retire_committed(rt, entry, reason, mode)
  if entry.retired then
    return entry
  end
  entry.closing = true
  entry.close_reason = reason
  entry.retire_mode = mode or (entry.mode == 'write' and 'abort' or 'immediate')
  self:_ensure_running(rt)
  self:_notify('retire', entry, reason, entry.retire_mode)
  return entry
end

function Reactor:_arm(entry)
  if entry.retired then
    return false
  end
  entry.armed = true
  if handle_hint_ready(entry) then
    self:hint(entry.key, entry.mode)
  end
  return true
end

function Reactor:_disarm(entry)
  entry.armed = false
  return true
end

function Reactor:_refresh(entry)
  if not entry or entry.retired or not entry.registered then
    return
  end
  if entry.closing and (entry.mode ~= 'write' or entry.retire_mode ~= 'drain') then
    self:_retire_entry(entry, entry.close_reason or 'closing')
    return
  end

  if entry.mode == 'read' then
    local terminal = entry.flow:_read_terminal_reason()
    if terminal then
      self:_retire_entry(entry, entry.close_reason or terminal)
    elseif entry.flow:_read_serviceable() then
      self:_arm(entry)
    else
      self:_disarm(entry)
    end
    return
  end

  if entry.mode == 'write' then
    local terminal = entry.flow:_write_terminal_reason(entry.closing and entry.retire_mode == 'drain')
    if terminal then
      self:_retire_entry(entry, entry.close_reason or terminal)
    elseif entry.lease or entry.flow:_write_serviceable() then
      self:_arm(entry)
    else
      self:_disarm(entry)
    end
    return
  end

  self:_retire_entry(entry, 'unsupported_reaction_mode')
end

local function combine_error(current, err)
  if err == nil then
    return current
  end
  if current == nil then
    return err
  end
  return {
    kind = 'multiple_close_errors',
    errors = { current, err },
  }
end

function Reactor:_retire_entry(entry, reason)
  if entry.retired then
    return entry.retire_error == nil, entry.retire_error
  end
  self:_disarm(entry)
  local registrations = self.by_key[key_id(entry.key)]
  if registrations then
    registrations[entry.id] = nil
    if next(registrations) == nil then
      self.by_key[key_id(entry.key)] = nil
    end
  end
  local flow_entries = self.flow_entries[entry.flow]
  if flow_entries then
    flow_entries[entry._fibers_id] = nil
    if next(flow_entries) == nil then
      self.flow_entries[entry.flow] = nil
    end
  end

  local retire_error
  if entry.lease then
    local ok, err = masked_perform(self.runtime, entry.lease:release_op())
    if not ok and err ~= Errors.NO_LEASE then
      retire_error = combine_error(retire_error, err)
    end
    entry.lease = nil
  end

  if entry.mode == 'read' then
    local ok, err = optional_shutdown(entry.handle, 'shutdown_read', reason)
    if not ok then
      retire_error = combine_error(retire_error, err or Errors.READ_ERROR)
    end
    masked_perform(self.runtime, entry.flow:inlet():close_op(reason))
  elseif entry.mode == 'write' then
    local ok, err = optional_shutdown(entry.handle, 'shutdown_write', reason)
    if not ok then
      retire_error = combine_error(retire_error, err or Errors.WRITE_ERROR)
    end
    masked_perform(self.runtime, entry.flow:outlet():close_op(reason))
  end

  entry.registered = false
  entry.retired = true
  entry.retire_error = retire_error
  self.entries[entry._fibers_id] = nil
  IOAudit.retire(entry, retire_error, reason)

  local stream = entry.stream
  if stream then
    stream._reactor_live = math.max(0, (stream._reactor_live or 1) - 1)
    if retire_error then
      stream._close_error = combine_error(stream._close_error, retire_error)
    end
    if stream._reactor_live == 0 and not stream._handle_closed then
      stream._handle_closed = true
      local ok, err = stream.handle:close(reason)
      if not ok then
        stream._close_error = combine_error(stream._close_error, err or Errors.FLOW_ERROR)
      end
    end
  end

  UnsafeExternalMutation.deliver(entry.retired_signal, retire_error == nil, retire_error)
  return retire_error == nil, retire_error
end

function Reactor:_service_read(entry)
  if not entry.flow:_read_serviceable() then
    self:_refresh(entry)
    return true
  end
  local space, reserve_err =
    masked_perform(self.runtime, entry.flow:inlet():reserve_some_op(entry.chunk_size, entry))
  if not space then
    if reserve_err then
      return self:_retire_entry(entry, reserve_err)
    end
    self:_refresh(entry)
    return true
  end

  local bytes, err = entry.handle:read(space:capacity())
  if bytes ~= nil and type(bytes) ~= 'string' then
    masked_perform(self.runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
    return self:_retire_entry(entry, Errors.BACKEND_PROTOCOL_ERROR)
  end
  if type(bytes) == 'string' and #bytes > space:capacity() then
    masked_perform(self.runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
    return self:_retire_entry(entry, Errors.BACKEND_PROTOCOL_ERROR)
  end

  if err == Errors.EOF or HostError.is_eof(err) then
    if bytes and #bytes > 0 then
      local n, commit_err = masked_perform(self.runtime, space:commit_op(bytes))
      if not n then
        masked_perform(self.runtime, space:fail_op(commit_err or Errors.BACKEND_PROTOCOL_ERROR))
        return self:_retire_entry(entry, commit_err or Errors.BACKEND_PROTOCOL_ERROR)
      end
    else
      masked_perform(self.runtime, space:release_op())
    end
    masked_perform(self.runtime, entry.flow:inlet():close_op(Errors.EOF))
    return self:_retire_entry(entry, Errors.EOF)
  end

  if HostError.is_would_block(err) then
    entry.would_block_count = entry.would_block_count + 1
    if bytes ~= nil and bytes ~= '' then
      masked_perform(self.runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
      return self:_retire_entry(entry, Errors.BACKEND_PROTOCOL_ERROR)
    end
    masked_perform(self.runtime, space:release_op())
    self:_refresh(entry)
    return true
  end

  if err ~= nil then
    if bytes ~= nil and bytes ~= '' then
      masked_perform(self.runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
      return self:_retire_entry(entry, Errors.BACKEND_PROTOCOL_ERROR)
    end
    masked_perform(self.runtime, space:fail_op(err))
    return self:_retire_entry(entry, err)
  end

  if bytes == nil or bytes == '' then
    masked_perform(self.runtime, space:fail_op(Errors.BACKEND_PROTOCOL_ERROR))
    return self:_retire_entry(entry, Errors.BACKEND_PROTOCOL_ERROR)
  end

  local n, commit_err = masked_perform(self.runtime, space:commit_op(bytes))
  if not n then
    masked_perform(self.runtime, space:fail_op(commit_err or Errors.BACKEND_PROTOCOL_ERROR))
    return self:_retire_entry(entry, commit_err or Errors.BACKEND_PROTOCOL_ERROR)
  end
  self:_refresh(entry)
  return true
end

function Reactor:_service_write(entry)
  local lease = entry.lease
  if not lease then
    if not entry.flow:_write_serviceable() then
      self:_refresh(entry)
      return true
    end
    local lease_err
    lease, lease_err =
      masked_perform(self.runtime, entry.flow:outlet():lease_some_op(entry.chunk_size, entry))
    if not lease then
      if lease_err == Errors.CLOSED_AND_DRAINED then
        return self:_retire_entry(entry, entry.close_reason or lease_err)
      end
      if lease_err then
        return self:_retire_entry(entry, lease_err)
      end
      self:_refresh(entry)
      return true
    end
    entry.lease = lease
  end

  local bytes = lease:bytes()
  local n, err = entry.handle:write(bytes)
  if n and n > 0 then
    local ok, ack_err = masked_perform(self.runtime, lease:ack_op(n))
    if not ok then
      entry.lease = nil
      masked_perform(self.runtime, entry.flow:outlet():fail_op(Errors.BACKEND_PROTOCOL_ERROR))
      return self:_retire_entry(entry, ack_err or Errors.BACKEND_PROTOCOL_ERROR)
    end
    -- Lease handles are immutable snapshots.  Reacquire after every
    -- acknowledgement so a partial write observes the remaining suffix.
    entry.lease = nil
  elseif HostError.is_would_block(err) or n == 0 then
    entry.would_block_count = entry.would_block_count + 1
    -- Retain byte custody and rearm the one-shot readiness registration.
  else
    entry.lease = nil
    masked_perform(self.runtime, entry.flow:outlet():fail_op(err or Errors.WRITE_ERROR))
    return self:_retire_entry(entry, err or Errors.WRITE_ERROR)
  end
  self:_refresh(entry)
  return true
end

function Reactor:_service_ready(id, generation)
  local entry = self.entries[id]
  if not entry or entry.retired or entry.generation ~= generation then
    IOAudit.stale_ready(self.runtime)
    return true
  end
  self.service_count = self.service_count + 1
  entry.service_count = entry.service_count + 1
  entry.last_service_sequence = self.service_count
  IOAudit.service(entry)
  if entry.mode == 'read' then
    return self:_service_read(entry)
  elseif entry.mode == 'write' then
    return self:_service_write(entry)
  end
  return self:_retire_entry(entry, 'unsupported_reaction_mode')
end

function Reactor:_handle_control(kind, entry, reason, mode)
  IOAudit.control(self.runtime)
  if not entry or entry.retired then
    return true
  end
  if kind == 'demand' then
    entry.demand_queued = false
    self:_refresh(entry)
  elseif kind == 'retire' then
    entry.closing = true
    entry.close_reason = reason or entry.close_reason
    entry.retire_mode = mode or entry.retire_mode
    self:_refresh(entry)
  elseif kind == 'registered' then
    self:_refresh(entry)
  end
  return true
end

local function control_record(kind, entry, reason, mode)
  return { kind = 'control', control = kind, entry = entry, reason = reason, mode = mode }
end

local function control_pending(control)
  return control ~= nil and control:length() > 0
end

function Reactor:_wait_option()
  local control = self.control:next_op():map(control_record)
  local ready = self.ready:next_op():map(function(id, generation, mode, key)
    return { kind = 'ready', id = id, generation = generation, mode = mode, key = key }
  end)
  -- Control arrivals and host readiness are temporal alternatives.  A host may
  -- deliver readiness after this option has suspended, so certified fallback is
  -- not the right relationship between them.  Bounded control draining below
  -- provides priority without discarding the readiness wait.
  return Op.choice(control, ready)
end

function Reactor:_drain_control(rt)
  local handled = 0
  while handled < self.control_quantum and control_pending(self.control) do
    -- The control queue has one consumer: this reactor task.  Inspecting its
    -- committed state before performing next_op avoids opening a second
    -- certified-fallback session merely to implement a non-blocking dequeue.
    local selected = masked_perform(rt, self.control:next_op():map(control_record))
    self:_handle_control(selected.control, selected.entry, selected.reason, selected.mode)
    handled = handled + 1
  end
  return handled
end

function Reactor:_run(rt)
  while true do
    self:_drain_control(rt)
    if next(self.entries) == nil then
      self.running = false
      return true
    end

    local selected = masked_perform(rt, self:_wait_option())
    if selected.kind == 'control' then
      self:_handle_control(selected.control, selected.entry, selected.reason, selected.mode)
    else
      -- A close or demand transition which arrived with readiness is applied
      -- first.  The generation check in _service_ready then rejects stale work.
      self:_drain_control(rt)
      self:_service_ready(selected.id, selected.generation)
    end
  end
end

function Reactor:hint(key, mode)
  mode = mode == 'wr' and 'write' or (mode or 'read')
  local registrations = self.by_key[key_id(key)]
  if not registrations then
    return false
  end
  local delivered = false
  for _, entry in pairs(registrations) do
    if entry.armed and not entry.retired and entry.mode == mode then
      entry.armed = false
      UnsafeExternalMutation.deliver(self.ready, entry.id, entry.generation, entry.mode, entry.key)
      delivered = true
    end
  end
  return delivered
end

function Reactor:_host_delivered(entry)
  local current = self.entries[entry.id]
  if current ~= entry or entry.retired or not entry.armed then
    return false
  end
  entry.armed = false
  return true
end

function Reactor:_host_active()
  local out = {}
  for _, entry in pairs(self.entries) do
    if entry.armed and not entry.retired then
      out[#out + 1] = entry
    end
  end
  return out
end

function Reactor:registration_count()
  local n = 0
  for _ in pairs(self.entries) do
    n = n + 1
  end
  return n
end

function Reactor:assert_quiescent(label)
  local names = {}
  for _, entry in pairs(self.entries) do
    names[#names + 1] = entry.name .. ':' .. entry.mode
  end
  if #names > 0 then
    table.sort(names)
    error((label or 'host reactor') .. ' still has registrations: ' .. table.concat(names, ', '), 2)
  end
  return true
end

Reactor.Entry = Entry
Reactor.ControlKind = ControlKind
return Reactor
