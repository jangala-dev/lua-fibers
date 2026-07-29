-- Bounded reactor-owned host offers.
--
-- Readiness-oriented hosts retain their existing non-blocking handle contract.
-- The runtime reactor reserves capacity, performs the authoritative host call,
-- and publishes the resulting value as an external fact.  Values remain under
-- this source's Lifetime until a committed next_op() transfers or consumes
-- them.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local Reactor = require('fibers.host.reactor')
local Closure = require('fibers.closure')
local Counter = require('fibers.resource.counter')
local EventQueue = require('fibers.resource.event_queue')
local Signal = require('fibers.resource.signal')
local UnsafeExternalMutation = require('fibers.host.unsafe_external_mutation')
local Lifetime = require('fibers.lifetime')
local Protected = require('fibers.protected')

local Offer = {}
Offer.__index = Offer
local next_id = 0
local unpack_ = table.unpack or unpack

local function source_error(source, state)
  if state and state.kind == 'failed' then
    return state.error
  end
  return source.error
    or HostError.closed(source.domain, source.action, {
      reason = state and state.reason or source.reason or 'offer source completed',
    })
end

local function aggregate_error(source, message, ...)
  local compact = {}
  for i = 1, select('#', ...) do
    local err = select(i, ...)
    if err ~= nil then
      compact[#compact + 1] = err
    end
  end
  if #compact == 0 then
    return nil
  end
  if #compact == 1 then
    return compact[1]
  end
  return HostError.protocol(source.domain, source.action, message, { errors = compact })
end

local function source_closure(source)
  return Closure.request_then_wait(function(_ctx, _record, close)
    return source:close_op(close.reason or 'offer source closed')
  end, function()
    return source:closed_op()
  end, {
    name = 'host_offer_source',
    finish_result = Closure.require_ok('host offer source closure failed'),
  })
end

function Offer.new(spec)
  spec = spec or {}
  if type(spec.pull) ~= 'function' then
    error('HostOfferSource requires pull', 2)
  end
  local mode = spec.mode or 'read'
  if mode ~= 'read' and mode ~= 'write' and mode ~= 'poll' then
    error('HostOfferSource mode must be read, write or poll', 2)
  end
  if mode ~= 'poll' and spec.handle == nil then
    error('HostOfferSource requires a handle or handle provider', 2)
  end
  if mode == 'poll' and spec.handle ~= nil then
    error('polling HostOfferSource must not provide a handle', 2)
  end
  local capacity = spec.capacity or 1
  if type(capacity) ~= 'number' or capacity < 1 or capacity % 1 ~= 0 then
    error('HostOfferSource capacity must be a positive integer', 2)
  end

  next_id = next_id + 1
  local name = spec.name or ('host-offer-' .. tostring(next_id))
  local source = setmetatable({
    kind = 'host_offer_source',
    name = name,
    _fibers_id = 'host-offer-' .. tostring(next_id),
    domain = spec.domain or 'host',
    action = spec.action or 'offer',
    role = spec.role or 'host_offer_source',
    mode = mode,
    poll_interval = spec.poll_interval,
    capacity = capacity,
    _one_shot = spec.one_shot == true,
    _handle_provider = spec.handle,
    _pull = spec.pull,
    _closed_error = spec.closed_error,
    _dispose = spec.dispose,
    _retired = spec.retired,
    _slots = Counter.bounded(capacity, name .. ':slots'),
    _queue = EventQueue.new(name .. ':offers'),
    _terminal = Signal.new(name .. ':terminal'),
  }, Offer)

  Lifetime.define(source, {
    name = name,
    role = source.role,
    closure = source_closure(source),
    children = spec.children,
  })

  local rt = Runtime.current()
  if not rt then
    error('HostOfferSource.new requires a current runtime', 2)
  end
  local reactor = Reactor.for_runtime(rt)
  source._entry = reactor:offer({
    name = source.name,
    mode = source.mode,
    source = source,
    handle = source.mode == 'poll' and nil or function()
      return source:_handle()
    end,
    poll_interval = source.poll_interval,
  })
  return source
end

function Offer:_handle()
  local value = self._handle_provider
  if type(value) == 'function' then
    value = value()
  end
  return value
end

function Offer:open_op(scope)
  return scope
    :admit_op(self)
    :and_then(function()
      return self._entry:register_op()
    end, false)
    :map(function()
      return self
    end)
end

function Offer:next_op()
  local offer = self._queue:next_op()
  local release = self._slots:give_op()
  local demand = self._entry:demand_op()
  local resume = Op.each({ release, demand })
  return offer:and_then(function(value)
    return resume:map(function()
      return value
    end)
  end, Op.dependencies(offer, release, demand))
end

function Offer:result_op()
  return self:next_op():or_else(self._terminal:wait_op():map(function(state)
    return nil, source_error(self, state)
  end))
end

function Offer:terminal_op()
  return self._terminal:wait_op():map(function(state)
    if state.kind == 'failed' or state.kind == 'cancelled' then
      return nil, source_error(self, state)
    end
    return true, self.error
  end)
end

function Offer:close_op(reason)
  return self._entry:retire_op(reason or 'offer source closed', 'discard')
end

function Offer:closed_op()
  return self._entry:retired_op()
end

function Offer:_publish_terminal(state)
  if self.state then
    return false
  end
  self.state = state
  self.reason = state.reason or self.reason
  if state.error then
    self.error = state.error
  end
  UnsafeExternalMutation.deliver(self._terminal, state)
  return true
end

function Offer:_drain_unclaimed(rt, reason)
  local errors = {}
  local packed = {}
  local count = self._queue:length()

  if count > 0 then
    local drained, values = Protected.pcall(rt._perform_current, rt, self._queue:_drain_op(), nil, true)
    if drained then
      packed = values
    else
      errors[#errors + 1] = values
    end
  end

  if type(self._dispose) == 'function' then
    for i = 1, #packed do
      local values = packed[i]
      local disposed, dispose_err = Protected.pcall(self._dispose, unpack_(values, 1, values.n), reason)
      if not disposed then
        errors[#errors + 1] =
          HostError.protocol(self.domain, self.action, 'unclaimed offer disposal raised', {
            index = i,
            cause = dispose_err,
          })
      end
    end
  end

  if #packed > 0 then
    local restored, restore_err =
      Protected.pcall(rt._perform_current, rt, self._slots:give_op(#packed), nil, true)
    if not restored then
      errors[#errors + 1] = restore_err
    end
  end

  local err = aggregate_error(self, 'one or more unclaimed offers failed to retire cleanly', unpack_(errors))
  if err then
    return nil, err
  end
  return true
end

function Offer:_reactor_retired(rt, state, preserve_offers)
  state = state or { kind = 'cancelled', reason = 'offer source retired' }
  local cleanup_error
  if not preserve_offers then
    local clean, err = self:_drain_unclaimed(rt, state.reason)
    if not clean then
      cleanup_error = err
    end
  end

  local terminal_state = state
  if cleanup_error then
    local combined = aggregate_error(self, 'offer source retirement failed', state.error, cleanup_error)
    terminal_state = {
      kind = 'failed',
      reason = state.reason or 'offer source retirement failed',
      error = combined,
    }
  end

  local retired_error
  if type(self._retired) == 'function' then
    local called, ok, err = Protected.pcall(self._retired, rt, terminal_state)
    if not called then
      retired_error = HostError.protocol(self.domain, self.action, 'offer retirement callback raised', {
        cause = ok,
      })
    elseif ok == nil or ok == false then
      retired_error = err or HostError.protocol(self.domain, self.action, 'offer retirement callback failed')
    end
  end
  if retired_error then
    terminal_state = {
      kind = 'failed',
      reason = terminal_state.reason or 'offer source retirement failed',
      error = aggregate_error(self, 'offer source retirement failed', terminal_state.error, retired_error),
    }
  end

  -- Terminal publication is unconditional with respect to disposal or owner
  -- retirement outcome: observers must always learn that the source has stopped.
  self:_publish_terminal(terminal_state)
  if cleanup_error or retired_error then
    return nil, terminal_state.error
  end
  return true
end

return Offer
