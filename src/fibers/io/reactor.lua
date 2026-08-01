-- Runtime-local executor for readiness-driven host reactions.
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
local Interest = require('fibers.embed.external').Interest
local UnsafeExternalMutation = require('fibers.embed.unsafe_external_mutation')
local Errors = require('fibers.resource.flow.errors')
local IOError = require('fibers.io.error')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local IOAudit = require('fibers.internal.io_audit')
local Protected = require('fibers.protected')
local Sleep = require('fibers.sleep')

local unpack_ = table.unpack or unpack
local function pack_(...) return { n = select('#', ...), ... } end

local Reactor = {}
Reactor.__index = Reactor
local Entry = {}
Entry.__index = Entry

local next_reactor = 0
local next_entry = 0

local function optional_shutdown(handle, name, reason)
  local ok, err = handle[name](handle, reason)
  if ok == nil and IOError.is_unsupported(err) then
    return true
  end
  return ok, err
end

local function handle_key(handle, mode)
  if not handle or type(handle.readiness_key) ~= 'function' then return nil end
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

-- Host pulls are authoritative, bounded reactor callbacks.  They must not yield
-- or enter Fibers scheduling.  A reusable worker coroutine lets us detect even a
-- raw coroutine.yield portably across Lua versions. Protected.pcall propagates
-- yields through its coroutine-backed fallback on Lua 5.1, while the outer worker
-- boundary turns any such yield into a reactor phase error. The worker is reused,
-- so this does not allocate one coroutine per pull.
local PULL_READY = {}
local PULL_DONE = {}

local function new_pull_worker()
  local worker = coroutine.create(function()
    local request = coroutine.yield(PULL_READY)
    while true do
      request.result = pack_(Protected.pcall(request.fn, unpack_(request.args, 1, request.args.n)))
      request = coroutine.yield(PULL_DONE)
    end
  end)
  local ok, marker = coroutine.resume(worker)
  if not ok or marker ~= PULL_READY then
    error('failed to initialise host reactor pull worker', 0)
  end
  return worker
end

local function call_nonyielding_pull(reactor, fn, ...)
  local worker = reactor._pull_worker
  if not worker or coroutine.status(worker) == 'dead' then
    worker = new_pull_worker()
    reactor._pull_worker = worker
  end

  local runtime = reactor.runtime
  local request = { fn = fn, args = pack_(...) }
  local old_phase = runtime:_set_phase('host_reactor_pull')
  local resumed = pack_(coroutine.resume(worker, request))
  runtime:_restore_phase(old_phase)

  if not resumed[1] then
    reactor._pull_worker = nil
    return false, resumed[2]
  end
  if resumed[2] ~= PULL_DONE then
    reactor._pull_worker = nil
    return false, runtime:_make_error('phase_error', 'host reactor pull may not yield', {
      phase = 'host_reactor_pull',
      action = 'pull',
    })
  end

  local result = request.result
  request.fn, request.args, request.result = nil, nil, nil
  return unpack_(result, 1, result.n)
end

local ControlKind
local function control_key(payload)
  return payload.reactor._fibers_id .. ':' .. payload.entry._fibers_id
end

ControlKind = Effect.kind({
  name = 'host_reactor_control',
  key = control_key,
  merge = function(a, b)
    if a.action == b.action then return a end
    if a.action == 'demand' then return b end
    if b.action == 'demand' then return a end
    return nil, {
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
        elseif p.action == 'demand' then
          p.reactor:_notify_demand(p.entry)
          p.reactor:_ensure_running(discharge_rt)
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
  local service = spec.service or 'flow'
  local handle
  if type(spec.handle) ~= 'function' then handle = spec.handle end
  local key = handle and handle_key(handle, spec.mode) or nil
  if service == 'flow' and key == nil then
    error('reactor-backed direction requires a readiness key', 3)
  end
  if service == 'callback' and key == nil then
    error('reactor callback requires a readiness key', 3)
  end
  if service == 'offer' and spec.mode ~= 'poll' and key == nil and type(spec.handle) ~= 'function' then
    error('reactor offer requires a readiness key or poll mode', 3)
  end
  local entry = setmetatable({
    kind = service == 'offer' and 'host_offer_reaction'
      or (service == 'callback' and 'host_callback_reaction' or 'host_reaction'),
    service = service,
    name = spec.name or id,
    mode = spec.mode,
    stream = spec.stream,
    flow = spec.flow,
    source = spec.source,
    callback = spec.callback,
    poll_interval = spec.poll_interval,
    next_poll = nil,
    handle = handle,
    handle_provider = spec.handle,
    reactor = reactor,
    chunk_size = spec.chunk_size or 4096,
    generation = spec.generation or next_entry,
    key = key,
    _fibers_id = id,
    id = id,
    armed = false,
  }, Entry)
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

  if service == 'flow' then
    local hidden_endpoint
    if entry.flow then
      hidden_endpoint = entry.mode == 'read' and entry.flow:inlet() or entry.flow:outlet()
    end
    Lifetime.define(entry, {
      name = entry.name,
      role = 'host_reaction',
      children = hidden_endpoint and { hidden_endpoint } or nil,
      closure = Closure.request_then_wait(
        function(_ctx, record, close)
          return record.item:retire_op(close.reason, record.item.mode == 'write' and 'abort' or 'immediate')
        end,
        function(_ctx, record)
          return record.item:retired_op()
        end,
        { name = 'host_reaction', finish_result = Closure.require_ok('reactor retirement failed') }
      ),
    })
    IOAudit.created(entry, { kind = 'reactor_registration' })
  end
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

function Entry:demand_op()
  return Op.emit(control_effect(self.reactor, self, 'demand')):map(function()
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
  self.ready = EventQueue.new(id .. ':ready', function(_runtime, queue, feed)
    return Interest.external(queue, 'poll', {
      external_kind = 'poller',
      poller = self,
      feed = feed,
    })
  end)
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

function Reactor:offer(spec)
  spec = spec or {}
  spec.service = 'offer'
  return Entry.new(self, spec)
end

function Reactor:callback(spec)
  spec = spec or {}
  if type(spec.callback) ~= 'function' then
    error('reactor callback requires spec.callback', 2)
  end
  spec.service = 'callback'
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
  if stream and stream._reactor_handle_attached then return end
  if entry.service == 'flow' and type(handle.attach_stream) == 'function' then
    handle:attach_stream(stream)
  end
  if type(handle.bind_runtime) == 'function' then handle:bind_runtime(rt) end
  if stream then stream._reactor_handle_attached = true end
end

function Reactor:_register_committed(rt, entry)
  if entry.retired then error('cannot register a retired reactor entry', 2) end
  if entry.registered then return entry end
  if entry.mode ~= 'poll' and not entry.handle then
    entry.handle = type(entry.handle_provider) == 'function' and entry.handle_provider() or entry.handle_provider
  end
  if entry.mode ~= 'poll' then
    if not entry.handle then error('reactor registration has no host handle', 2) end
    if entry.key == nil then entry.key = handle_key(entry.handle, entry.mode) end
    if entry.key == nil then error('reactor registration requires a readiness key', 2) end
    self:_attach_handle(rt, entry)
  end
  entry.registered = true
  self.entries[entry._fibers_id] = entry
  IOAudit.register(entry, rt, { mode = entry.mode, key = entry.key })
  if entry.key ~= nil then
    local key = key_id(entry.key)
    local registrations = self.by_key[key]
    if not registrations then
      registrations = {}
      self.by_key[key] = registrations
    end
    registrations[entry.id] = entry
  end
  if entry.flow then
    local flow_entries = self.flow_entries[entry.flow]
    if not flow_entries then
      flow_entries = {}
      self.flow_entries[entry.flow] = flow_entries
    end
    flow_entries[entry._fibers_id] = entry
  end
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
  if entry.mode == 'poll' then
    entry.next_poll = entry.next_poll or self.runtime:now()
  elseif handle_hint_ready(entry) then
    self:hint(entry.key, entry.mode)
  end
  return true
end

function Reactor:_disarm(entry)
  entry.armed = false
  return true
end

function Reactor:_refresh(entry)
  if not entry or entry.retired or not entry.registered then return end
  if entry.service == 'offer' then
    if entry.closing then
      self:_retire_entry(entry, entry.close_reason or 'closing')
    elseif entry.source._slots.value > 0 then
      self:_arm(entry)
    else
      self:_disarm(entry)
    end
    return
  end
  if entry.service == 'callback' then
    if entry.closing then
      self:_retire_entry(entry, entry.close_reason or 'closing')
    else
      self:_arm(entry)
    end
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
  if entry.retired then return entry.retire_error == nil, entry.retire_error end
  self:_disarm(entry)
  if entry.key ~= nil then
    local registrations = self.by_key[key_id(entry.key)]
    if registrations then
      registrations[entry.id] = nil
      if next(registrations) == nil then self.by_key[key_id(entry.key)] = nil end
    end
  end
  if entry.flow then
    local flow_entries = self.flow_entries[entry.flow]
    if flow_entries then
      flow_entries[entry._fibers_id] = nil
      if next(flow_entries) == nil then self.flow_entries[entry.flow] = nil end
    end
  end

  local retire_error = entry.retire_error
  if entry.service == 'offer' then
    local state = entry.retire_state or { kind = 'cancelled', reason = reason or 'offer source retired' }
    local called, retired_ok, retired_err = Protected.pcall(
      entry.source._reactor_retired,
      entry.source,
      self.runtime,
      state,
      entry.preserve_offers == true
    )
    if not called then
      retire_error = retired_ok
    elseif not retired_ok then
      retire_error = retired_err
    end
  elseif entry.service == 'flow' then
    if entry.lease then
      local ok, err = masked_perform(self.runtime, entry.lease:release_op())
      if not ok and err ~= Errors.NO_LEASE then retire_error = combine_error(retire_error, err) end
      entry.lease = nil
    end

    if entry.mode == 'read' then
      local ok, err = optional_shutdown(entry.handle, 'shutdown_read', reason)
      if not ok then retire_error = combine_error(retire_error, err or Errors.READ_ERROR) end
      masked_perform(self.runtime, entry.flow:inlet():close_op(reason))
    elseif entry.mode == 'write' then
      local ok, err = optional_shutdown(entry.handle, 'shutdown_write', reason)
      if not ok then retire_error = combine_error(retire_error, err or Errors.WRITE_ERROR) end
      masked_perform(self.runtime, entry.flow:outlet():close_op(reason))
    end
  end

  entry.registered = false
  entry.retired = true
  entry.retire_error = retire_error
  self.entries[entry._fibers_id] = nil
  IOAudit.retire(entry, retire_error, reason)

  local stream = entry.stream
  if stream then
    stream._reactor_live = math.max(0, (stream._reactor_live or 1) - 1)
    if retire_error then stream._close_error = combine_error(stream._close_error, retire_error) end
    if stream._reactor_live == 0 and not stream._handle_closed then
      stream._handle_closed = true
      local ok, err = stream.handle:close(reason)
      if not ok then stream._close_error = combine_error(stream._close_error, err or Errors.FLOW_ERROR) end
    end
  end

  UnsafeExternalMutation.deliver(entry.retired_signal, retire_error == nil, retire_error)
  return retire_error == nil, retire_error
end

local function release_offer_slot(reactor, source)
  local ok, err = masked_perform(reactor.runtime, source._slots:give_op())
  if not ok then return nil, err end
  return true
end

function Reactor:_service_offer(entry)
  local source = entry.source
  if entry.mode == 'poll' then
    entry.armed = false
    entry.next_poll = nil
  end
  if source._slots.value <= 0 then
    self:_refresh(entry)
    return true
  end

  local reserved, reserve_err = masked_perform(self.runtime, source._slots:take_op())
  if not reserved then
    if reserve_err then
      entry.retire_state = { kind = 'failed', error = reserve_err }
      return self:_retire_entry(entry, 'offer capacity reservation failed')
    end
    self:_refresh(entry)
    return true
  end

  local ok, value, err = call_nonyielding_pull(self, source._pull, entry.handle)
  if not ok then
    release_offer_slot(self, source)
    local failure = IOError.is(value) and value or IOError.protocol(source.domain, source.action, tostring(value), {
      cause = value,
    })
    entry.retire_state = { kind = 'failed', error = failure }
    return self:_retire_entry(entry, 'offer source pull failed')
  end

  if value ~= nil then
    UnsafeExternalMutation.deliver(source._queue, value)
    if source._one_shot then
      entry.retire_state = { kind = 'succeeded', reason = 'one-shot offer published' }
      entry.preserve_offers = true
      return self:_retire_entry(entry, 'one-shot offer published')
    end
    self:_refresh(entry)
    -- Once readiness has yielded one value, drain authoritatively until either
    -- capacity is exhausted or the host reports would-block. This avoids losing
    -- already-buffered accepts or datagrams when a backend clears its readiness
    -- hint on every syscall.
    if entry.armed then self:hint(entry.key, entry.mode) end
    return true
  end

  local released, release_err = release_offer_slot(self, source)
  if not released then
    entry.retire_state = { kind = 'failed', error = release_err }
    return self:_retire_entry(entry, 'offer capacity release failed')
  end

  if IOError.is_would_block(err) then
    entry.would_block_count = entry.would_block_count + 1
    if entry.mode == 'poll' then
      entry.next_poll = self.runtime:now() + (entry.poll_interval or 0.025)
    end
    self:_refresh(entry)
    return true
  end

  if IOError.is(err, 'closed') or IOError.is_eof(err) then
    source.error = source._closed_error and source._closed_error(err) or err
    entry.retire_state = { kind = 'succeeded', reason = 'host source closed' }
    return self:_retire_entry(entry, 'host source closed')
  end

  local failure = IOError.normalise(err, { domain = source.domain, action = source.action })
  entry.retire_state = { kind = 'failed', error = failure }
  return self:_retire_entry(entry, 'host source failed')
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

  if err == Errors.EOF or IOError.is_eof(err) then
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

  if IOError.is_would_block(err) then
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
    -- Lease handles are captured snapshots.  Reacquire after every
    -- acknowledgement so a partial write observes the remaining suffix.
    entry.lease = nil
  elseif IOError.is_would_block(err) or n == 0 then
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

function Reactor:_service_callback(entry)
  local ok, serviced, err = call_nonyielding_pull(self, entry.callback, entry.handle)
  if not ok then
    entry.retire_error = IOError.is(serviced) and serviced
      or IOError.protocol('host', 'reactor_callback', tostring(serviced), { cause = serviced, name = entry.name })
    return self:_retire_entry(entry, 'reactor callback raised')
  end
  if serviced == nil or serviced == false then
    if IOError.is_would_block(err) then
      entry.would_block_count = entry.would_block_count + 1
      self:_refresh(entry)
      return true
    end
    entry.retire_error = IOError.normalise(err, { domain = 'host', action = 'reactor_callback' })
    return self:_retire_entry(entry, 'reactor callback failed')
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
  if entry.service == 'offer' then return self:_service_offer(entry) end
  if entry.service == 'callback' then return self:_service_callback(entry) end
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
    if entry.service == 'offer' and entry.armed and entry.mode ~= 'poll' then
      -- Capacity becoming available is itself reason to make one authoritative
      -- non-blocking probe. A would-block result then returns the source to
      -- readiness-driven service.
      self:hint(entry.key, entry.mode)
    end
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

local function control_pending(control)
  return control ~= nil and control:length() > 0
end

function Reactor:_next_poll_deadline()
  local deadline
  for _, entry in pairs(self.entries) do
    if entry.armed and not entry.retired and entry.mode == 'poll' and entry.next_poll ~= nil then
      if deadline == nil or entry.next_poll < deadline then deadline = entry.next_poll end
    end
  end
  return deadline
end

function Reactor:_wait_option()
  local alternatives = {
    control = self.control:next_op(),
    ready = self.ready:next_op(),
  }
  local deadline = self:_next_poll_deadline()
  if deadline ~= nil then
    alternatives.poll = Sleep.sleep_until_op(deadline)
  end
  -- Control arrivals and host readiness are temporal alternatives. A host may
  -- deliver readiness after this option has suspended, so certified fallback is
  -- not the right relationship between them. Bounded control draining below
  -- provides priority without discarding the readiness wait.
  return Op.named_choice(alternatives)
end

function Reactor:_service_due_polls()
  local now = self.runtime:now()
  local due = {}
  for _, entry in pairs(self.entries) do
    if entry.armed and not entry.retired and entry.mode == 'poll' and entry.next_poll ~= nil and entry.next_poll <= now then
      due[#due + 1] = entry
    end
  end
  table.sort(due, function(a, b) return a.id < b.id end)
  for i = 1, #due do
    local entry = due[i]
    if entry.armed and not entry.retired then
      self:_service_ready(entry.id, entry.generation)
    end
  end
  return #due
end

function Reactor:_drain_control(rt)
  local handled = 0
  while handled < self.control_quantum and control_pending(self.control) do
    -- The control queue has one consumer: this reactor task.  Inspecting its
    -- committed state before performing next_op avoids opening a second
    -- certified-fallback session merely to implement a non-blocking dequeue.
    local kind, entry, reason, mode = masked_perform(rt, self.control:next_op())
    self:_handle_control(kind, entry, reason, mode)
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

    local selected, a, b, c = masked_perform(rt, self:_wait_option())
    if selected == 'control' then
      self:_handle_control(a, b, c)
    elseif selected == 'poll' then
      self:_drain_control(rt)
      self:_service_due_polls()
    else
      -- A close or demand transition which arrived with readiness is applied
      -- first. The generation check in _service_ready then rejects stale work.
      self:_drain_control(rt)
      self:_service_ready(a, b)
    end
  end
end

function Reactor:hint(key, mode)
  mode = mode or 'read'
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
    if entry.armed and not entry.retired and entry.mode ~= 'poll' then
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
