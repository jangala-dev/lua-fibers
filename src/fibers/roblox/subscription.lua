---Lifetime-backed adaptation of an RBXScriptSignal into a Fibers event source.

local External = require('fibers.embed.external')
local Runtime = require('fibers.runtime')
local Op = require('fibers.op')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')

local Subscription = {}
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
  return Closure.protocol({
    name = 'roblox_subscription_disconnect',
    finish_op = function()
      return Op.always(true):wrap(function()
        subscription:_disconnect()
        return true
      end)
    end,
  })
end

local function delivery_for(self, packed)
  if self._closed then
    return
  end
  self.feed:set(unpack_(packed, 1, packed.n))
end

local function replacement_delivery_for(self, packed)
  if self._closed then
    return
  end
  -- `latest` and `pulse` have at most one pending observation, even when the
  -- consumer lags across several host turns. Clearing and publishing happen at
  -- the external-driver boundary, outside proof search.
  self.feed:clear()
  self.feed:set(unpack_(packed, 1, packed.n))
end

function Subscription:_queue_events(...)
  local packed = pack(...)
  self.host:enqueue(delivery_for, self, packed)
end

function Subscription:_queue_latest(...)
  self._latest = pack(...)
  if self._delivery_pending then
    return
  end
  self._delivery_pending = true
  self.host:enqueue(function(subscription)
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
  local connection = self.connection
  if connection and type(connection.Disconnect) == 'function' then
    -- Keep the connection and open state intact until Disconnect succeeds. A
    -- failed closure must retain enough truth and authority to be retried.
    connection:Disconnect()
  end
  self.connection = nil
  self._closed = true
  self._latest = nil
  self._delivery_pending = false
  return true
end

function Subscription.new(signal, opts)
  opts = opts or {}
  signal = require_signal(signal)
  local runtime = require_runtime(opts)
  local scope = require_scope(opts)
  local host = require_host(runtime, opts)
  local mode = opts.mode or 'events'
  if mode ~= 'events' and mode ~= 'latest' and mode ~= 'pulse' then
    error('Roblox subscription mode must be events, latest or pulse', 2)
  end

  local name = opts.name or ('roblox-' .. mode)
  local resource, feed = External.events(runtime)
  resource:label(name)
  local self = setmetatable({
    name = name,
    mode = mode,
    runtime = runtime,
    scope = scope,
    host = host,
    resource = resource,
    feed = feed,
    connection = nil,
    _closed = false,
    _latest = nil,
    _delivery_pending = false,
    _pulse_version = 0,
  }, Subscription)

  Lifetime.define(self, {
    label = name,
    role = 'roblox_subscription',
    closure = closure_protocol(self),
    meta = { mode = mode, name = name },
  })
  scope:perform(scope:admit_op(self))

  local callback
  if mode == 'events' then
    callback = function(...)
      self:_queue_events(...)
    end
  elseif mode == 'latest' then
    callback = function(...)
      self:_queue_latest(...)
    end
  else
    callback = function()
      self:_queue_pulse()
    end
  end

  -- Admission happens before connecting. If Connect fails, scope unwinding still
  -- owns and retires the dormant subscription Lifetime; no unmanaged connection can leak.
  self.connection = signal:Connect(callback)
  return self
end

---Return an option for the next queued or retained observation.
function Subscription:next_op()
  return self.resource:next_op()
end

---Wait directly for the next queued or retained observation.

---Return the number of observations currently pending in Fibers.
function Subscription:length()
  return self.resource:length()
end

---Report whether the underlying Roblox connection is still live.
function Subscription:is_connected()
  if self._closed or self.connection == nil then
    return false
  end
  local connected = self.connection.Connected
  return connected == nil or connected == true
end

---Report whether successful closure disconnected the subscription.
function Subscription:is_closed()
  return self._closed
end

---Return an option which retires this subscription from its owning scope.
function Subscription:close_op(reason)
  if self._closed then
    return require('fibers.op').always(true)
  end
  return Closure.close_op(self.scope, self, reason or 'subscription closed')
end

---Retire and disconnect the subscription through its owning Scope.
function Subscription:close(reason)
  if self._closed then
    return true
  end
  return self.scope:perform(self:close_op(reason))
end

Direct.install(Subscription, { 'next' })

return Subscription
