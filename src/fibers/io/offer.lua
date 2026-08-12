-- Bounded reactor-owned host offers.
--
-- Readiness-oriented hosts retain their existing non-blocking handle contract.
-- The runtime reactor reserves capacity, performs the authoritative host call,
-- and publishes the resulting value as an external fact.  Values remain under
-- this source's Lifetime until a committed next_op() transfers or consumes
-- them.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Reactor = require('fibers.io.reactor')
local IO = require('fibers.io.facility')
local EventQueue = require('fibers.resource.event_queue')
local Lifetime = require('fibers.lifetime')
local Protected = require('fibers.protected')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local Offer = {}
Offer.__index = Offer
local next_id = 0
local unpack_ = table.unpack or unpack

local OFFER_SPEC = {
  pull = Contract.func, mode = true, handle = true, capacity = Contract.positive_integer,
  label = Contract.non_empty_string, domain = Contract.non_empty_string,
  action = Contract.non_empty_string, role = Contract.non_empty_string,
  poll_interval = Contract.non_negative_number, one_shot = Contract.boolean,
  closed_error = true, dispose = Contract.func, retired = Contract.func,
  children = Contract.table,
}

local function source_error(source, state)
  if state and state.error then return state.error end
  return IOError.closed(source._domain, source._action, {
    reason = state and state.reason or 'offer source completed',
  })
end

local function aggregate_error(source, message, ...)
  local compact = {}
  for i = 1, select('#', ...) do
    local err = select(i, ...)
    if err ~= nil then compact[#compact + 1] = err end
  end
  if #compact == 0 then return nil end
  if #compact == 1 then return compact[1] end
  return IOError.protocol(source._domain, source._action, message, { errors = compact })
end

function Offer.new(spec)
  spec = Contract.record(spec, OFFER_SPEC, 'HostOfferSource spec', 2)
  if spec.pull == nil then error('HostOfferSource requires pull', 2) end
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

  next_id = next_id + 1
  local id = 'host-offer-' .. tostring(next_id)
  local label = spec.label
  local source = Label.attach(setmetatable({
    kind = 'host_offer_source',
    _fibers_id = id,
    _domain = spec.domain or 'host',
    _action = spec.action or 'offer',
    _role = spec.role or 'host_offer_source',
    _mode = mode,
    _poll_interval = spec.poll_interval,
    _capacity = capacity,
    _one_shot = spec.one_shot or false,
    _handle_provider = spec.handle,
    _pull = spec.pull,
    _closed_error = spec.closed_error,
    _dispose = spec.dispose,
    _retired = spec.retired,
    _queue = EventQueue.new(),
  }, Offer), label)
  Label.child(source._queue, source, 'offers')

  Lifetime.define(source, {
    label = label,
    role = source._role,
    closure = IO._closeable_closure(source, {
      name = 'host_offer_source', reason = 'offer source closed',
      finish_result = 'host offer source closure failed',
    }),
    children = spec.children,
  })

  local rt = Runtime.current()
  if not rt then error('HostOfferSource.new requires a current runtime', 2) end
  local reactor = Reactor.for_runtime(rt)
  source._entry = reactor:offer({
    label = Label.describe(source, source._fibers_id),
    mode = source._mode,
    source = source,
    handle = source._mode == 'poll' and nil or function() return source:_handle() end,
    poll_interval = source._poll_interval,
  })
  return source
end

function Offer:_handle()
  local value = self._handle_provider
  if type(value) == 'function' then value = value() end
  return value
end

function Offer:open_op(scope)
  return scope:admit_op(self)
    :and_then(self._entry:register_op())
    :map(function() return self end)
end

function Offer:next_op()
  return self._queue:next_op():and_then(Op.guard(function(value)
    return self._entry:demand_op():map(function() return value end)
  end))
end

function Offer:result_op()
  return self:next_op():or_else(self._entry:retired_op():map(function()
    return nil, source_error(self, self._entry.retire_state)
  end))
end

function Offer:terminal_op()
  return self._entry:retired_op():map(function(retired, retire_err)
    if not retired then return nil, retire_err end
    local state = self._entry.retire_state
    if state and (state.kind == 'failed' or state.kind == 'cancelled') then
      return nil, source_error(self, state)
    end
    return true, state and state.error
  end)
end

function Offer:request_close_op(reason)
  return self._entry:retire_op(reason or 'offer source closed', 'discard')
end

function Offer:closed_op()
  return self._entry:retired_op()
end

function Offer:_drain_unclaimed(rt, reason)
  local errors = {}
  local packed = {}
  local count = self._queue:_count()

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
        errors[#errors + 1] = IOError.protocol(self._domain, self._action, 'unclaimed offer disposal raised', {
          index = i,
          cause = dispose_err,
        })
      end
    end
  end

  local err = aggregate_error(self, 'one or more unclaimed offers failed to retire cleanly', unpack_(errors))
  if err then return nil, err end
  return true
end

function Offer:_reactor_retired(rt, state, preserve_offers)
  state = state or { kind = 'cancelled', reason = 'offer source retired' }
  local cleanup_error
  if not preserve_offers then
    local clean, err = self:_drain_unclaimed(rt, state.reason)
    if not clean then cleanup_error = err end
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
      retired_error = IOError.protocol(self._domain, self._action, 'offer retirement callback raised', {
        cause = ok,
      })
    elseif ok == nil or ok == false then
      retired_error = err or IOError.protocol(self._domain, self._action, 'offer retirement callback failed')
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
  self._entry.retire_state = terminal_state
  if cleanup_error or retired_error then return nil, terminal_state.error end
  return true
end

return Offer
