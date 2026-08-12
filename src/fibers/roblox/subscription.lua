---Lifetime-backed adaptation of an RBXScriptSignal into a Fibers event source.

local External = require('fibers.embed.external')
local Runtime = require('fibers.runtime')
local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')
local Completion = require('fibers.resource.completion')
local Protected = require('fibers.protected')
local Lifetime = require('fibers.lifetime')
local Label = require('fibers.internal.label')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Contract = require('fibers.internal.contract')

local Subscription = {}

local SUBSCRIPTION_OPTIONS = { runtime = true, scope = true, host = true, mode = true, label = true }
local next_subscription = 0
Subscription.__index = Subscription

local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function require_signal(signal)
  if type(signal) ~= 'table' and type(signal) ~= 'userdata' then
    error('Roblox subscription expects an RBXScriptSignal-like value', 3)
  end
  local connect = signal.Connect
  if type(connect) ~= 'function' then
    error('Roblox subscription signal requires Connect', 3)
  end
  return signal
end

local function require_runtime(opts)
  local runtime = opts.runtime or Runtime.current()
  if not runtime then
    error('Roblox subscription must be created from a running fiber or given opts.runtime', 3)
  end
  return runtime
end

local function require_scope(opts)
  local scope = opts.scope or (Runtime.current_scope and Runtime.current_scope())
  if type(scope) ~= 'table' or scope._fibers_scope ~= true then
    error('Roblox subscription requires a current Scope or opts.scope', 3)
  end
  return scope
end

local function require_host(runtime, opts)
  local host = opts.host or runtime.host
  if type(host) ~= 'table' or host.kind ~= 'roblox' or type(host.enqueue) ~= 'function' then
    error('Roblox subscription requires a fibers.roblox.host host', 3)
  end
  return host
end

local function closure_protocol(subscription)
  return Closure.request_then_wait(
    function(_ctx, _entry, reason)
      return subscription:request_close_op(reason or 'subscription retired')
    end,
    function()
      return subscription:closed_op()
    end,
    {
      name = 'roblox_subscription_disconnect',
      finish_result = Closure.require_ok('Roblox subscription disconnect failed'),
    }
  )
end

local function delivery_for(self, packed)
  if self._closed then
    return
  end
  self._feed:set(unpack_(packed, 1, packed.n))
end

local function replacement_delivery_for(self, packed)
  if self._closed then
    return
  end
  -- `latest` and `pulse` have at most one pending observation, even when the
  -- consumer lags across several host turns. Clearing and publishing happen at
  -- the external-driver boundary, outside proof search.
  self._feed:clear()
  self._feed:set(unpack_(packed, 1, packed.n))
end

function Subscription:_queue_events(...)
  local packed = pack(...)
  self._host:enqueue(delivery_for, self, packed)
end

function Subscription:_queue_latest(...)
  self._latest = pack(...)
  if self._delivery_pending then
    return
  end
  self._delivery_pending = true
  self._host:enqueue(function(subscription)
    subscription._delivery_pending = false
    local packed = subscription._latest
    subscription._latest = nil
    if packed then
      replacement_delivery_for(subscription, packed)
    end
  end, self)
end

function Subscription:_queue_pulse()
  self._pulse_version = self._pulse_version + 1
  self:_queue_latest(self._pulse_version)
end

function Subscription:_disconnect()
  if self._closed then
    return true
  end
  local connection = self._connection
  if connection and type(connection.Disconnect) == 'function' then
    -- Keep the connection and open state intact until Disconnect succeeds. A
    -- failed closure must retain enough truth and authority to be retried.
    connection:Disconnect()
  end
  self._connection = nil
  self._closed = true
  self._latest = nil
  self._delivery_pending = false
  return true
end

function Subscription:ready_op()
  return self._ready:result_op():map(function(ok, err)
    if not ok then return nil, err end
    return self
  end)
end

function Subscription:request_close_op(reason)
  reason = reason or 'subscription retired'
  local subscription = self
  return self._lifetime:request_close_op(reason):and_then(
    self._disconnect_state:read_op():and_then(Op.guard(function(state)
      if subscription._closed or state.kind == 'succeeded' then
        return subscription._disconnect_state:write_op({
          kind = 'succeeded', version = state.version or 0, reason = reason,
        }):map(function() return true, false end)
      end
      if state.kind == 'pending' then
        return Op.always(true, false)
      end
      return subscription._disconnect_state:write_op({
        kind = 'pending', version = (state.version or 0) + 1, reason = reason,
      }):map(function() return true, true end)
    end))
  )
end

function Subscription:closed_op()
  return self._disconnect_state:select_op(function(state)
    if state.kind == 'succeeded' then return Op.always(true) end
    if state.kind == 'failed' then return Op.always(nil, state.error) end
  end)
end

function Subscription:close(reason)
  local requested, request_err = perform(self:request_close_op(reason))
  if not requested then return nil, request_err end
  return perform(self:closed_op())
end

local function subscription_callback(subscription)
  if subscription._mode == 'events' then
    return function(...) subscription:_queue_events(...) end
  end
  if subscription._mode == 'latest' then
    return function(...) subscription:_queue_latest(...) end
  end
  return function() subscription:_queue_pulse() end
end

local function publish_ready(subscription, ...)
  return perform(subscription._ready:publish_success_op(...))
end

local function drive_subscription(subscription, signal)
  local connected, connection_or_err = Protected.pcall(signal.Connect, signal, subscription_callback(subscription))
  if not connected then
    perform(subscription._disconnect_state:write_op({ kind = 'succeeded', version = 0, reason = 'connect failed' }))
    perform(subscription._ready:publish_failure_op(connection_or_err))
    return nil, connection_or_err
  end
  subscription._connection = connection_or_err
  publish_ready(subscription, true)

  while true do
    local state = perform(subscription._disconnect_state:select_op(function(value)
      if value.kind == 'pending' or value.kind == 'succeeded' then return Op.always(value) end
    end))
    if state.kind == 'succeeded' then return true end

    local disconnected, result_or_err = Protected.pcall(subscription._disconnect, subscription)
    if disconnected and result_or_err then
      perform(subscription._disconnect_state:write_op({
        kind = 'succeeded', version = state.version, reason = state.reason,
      }))
      return true
    end

    local err = disconnected and 'subscription disconnect failed' or result_or_err
    perform(subscription._disconnect_state:write_op({
      kind = 'failed', version = state.version, reason = state.reason, error = err,
    }))
    -- Remain alive. A Closure retry moves the managed state back to pending and
    -- gives this driver another attempt without losing the live connection.
  end
end

function Subscription.new(signal, opts)
  opts = Contract.options(opts, SUBSCRIPTION_OPTIONS, 'Roblox Subscription options', 2)
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'Roblox Subscription label', 2) end
  signal = require_signal(signal)
  local runtime = require_runtime(opts)
  local scope = require_scope(opts)
  local host = require_host(runtime, opts)
  local mode = opts.mode or 'events'
  if mode ~= 'events' and mode ~= 'latest' and mode ~= 'pulse' then
    error('Roblox subscription mode must be events, latest or pulse', 2)
  end

  next_subscription = next_subscription + 1
  local id = 'roblox-subscription-' .. tostring(next_subscription)
  local resource, feed = External.events(runtime)
  local self = Label.attach(setmetatable({
    _fibers_id = id,
    _mode = mode,
    _runtime = runtime,
    _scope = scope,
    _host = host,
    _resource = resource,
    _feed = feed,
    _ready = Completion.new(),
    _disconnect_state = Cell.new({ kind = 'idle', version = 0 }),
    _connection = nil,
    _closed = false,
    _latest = nil,
    _delivery_pending = false,
    _pulse_version = 0,
  }, Subscription), opts.label)
  Label.child(resource, self, 'events')
  Label.child(self._ready, self, 'ready')
  Label.child(self._disconnect_state, self, 'disconnect')

  scope:perform(scope:_drive_op(self, {
    label = Label.get(self),
    role = 'roblox_subscription',
    closure = closure_protocol(self),
    run = function() return drive_subscription(self, signal) end,
  }))

  local ready, ready_err = self:ready()
  if not ready then
    -- Connection never became externally live. Structural retirement still
    -- removes the admitted Lifetime before the constructor reports failure.
    self:retire('subscription connect failed')
    error(ready_err, 0)
  end
  return self
end

---Return an option for the next queued or retained observation.
function Subscription:next_op()
  return self._resource:next_op()
end

---Wait directly for the next queued or retained observation.

function Subscription:retired_op()
  return Lifetime.require(self):retired_op():map(function() return self end)
end

---Transactionally start retirement of this subscription from its owning Scope.
function Subscription:start_retire_op(reason)
  if self._closed then
    return require('fibers.op').always(nil)
  end
  return Closure.start_retire_op(self._scope, self, reason or 'subscription retired')
end

---Retire and disconnect the subscription through its owning Scope.
function Subscription:retire(reason)
  if self._closed then return true end
  local process = self._scope:perform(self:start_retire_op(reason))
  local ok, result = self._scope:perform(process:result_op())
  if not ok then error(result, 0) end
  return result
end

Direct.install(Subscription, { 'next', 'ready', 'request_close', 'closed', 'retired' })

return Subscription
