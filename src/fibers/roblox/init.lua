---Roblox integration for Fibers.
---
---Roblox owns the engine scheduler and frame lifecycle. Fibers is embedded as a
---bounded subsystem: `prepare` creates the runtime, `Application:advance`
---consumes a host-supplied time horizon, and `attach` adds event- or phase-driven
---scheduling above that canonical boundary.
---
---RBXScriptSignal callbacks only queue external facts. They never invoke the
---proof engine recursively.

local External = require('fibers.embed.external')
local Runtime = require('fibers.runtime')
local Host = require('fibers.roblox.host')
local Application = require('fibers.roblox.app')
local Subscription = require('fibers.roblox.subscription')
local perform = require('fibers.perform')

local Roblox = {
  Host = Host,
  Application = Application,
  Subscription = Subscription,
}

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function current_context(opts)
  opts = opts or {}
  local runtime = opts.runtime or Runtime.current()
  if not runtime then
    error('Roblox adapter requires a running fibre or opts.runtime', 3)
  end
  local scope = opts.scope or (Runtime.current_scope and Runtime.current_scope())
  if type(scope) ~= 'table' or scope._fibers_scope ~= true then
    error('Roblox adapter requires a current Scope or opts.scope', 3)
  end
  local host = opts.host or runtime.host
  if type(host) ~= 'table' or host.kind ~= 'roblox' then
    error('Roblox adapter requires a fibers.roblox.host host', 3)
  end
  return runtime, scope, host
end

---Subscribe to every firing of an RBXScriptSignal.
---
---Each firing is queued, including nil-bearing argument lists. The connection is
---under the current Scope's custody and disconnects during closure. Create
---subscriptions from committed fibre code, not a speculative callback.
function Roblox.events(signal, opts)
  opts = copy(opts)
  opts.mode = 'events'
  return Subscription.new(signal, opts)
end

---Subscribe to the newest pending value of an RBXScriptSignal.
---
---Firing bursts are coalesced before host delivery and each delivered value
---replaces any older unconsumed value. This suits state-like observations.
function Roblox.latest(signal, opts)
  opts = copy(opts)
  opts.mode = 'latest'
  return Subscription.new(signal, opts)
end

---Subscribe to coalesced invalidation pulses from an RBXScriptSignal.
---
---Each engine firing increments a logical generation. Consumers receive only the
---newest pending generation, which suits frame and property invalidation signals.
function Roblox.pulse(signal, opts)
  opts = copy(opts)
  opts.mode = 'pulse'
  return Subscription.new(signal, opts)
end

---Create a Roblox host boundary without preparing an application.
---
---The host is non-blocking. It supplies time, queues external observations and
---coalesces requests for a later application turn.
function Roblox.new_host(opts)
  return Host.new(opts)
end

local function application_options(opts, host, owns_host)
  local out = copy(opts)
  out.host = host
  out.owns_host = owns_host
  out.host_config = nil
  out.await_timeout = nil
  return out
end

---Prepare a manually driven Fibers application.
---
---This is the canonical Roblox embedding interface. The caller retains control
---of the engine loop and invokes `app:advance({ horizon = ... })` at suitable
---boundaries. No Roblox task or RunService connection is created.
function Roblox.prepare(fn, opts)
  opts = opts or {}
  local host = opts.host or Host.new(opts.host_config)
  local owns_host = opts.owns_host
  if owns_host == nil then
    owns_host = opts.host == nil
  end
  return Application.new(fn, application_options(opts, host, owns_host))
end

---Prepare and attach a Fibers application to Roblox scheduling.
---
---`scheduling = "event"` is the default. It runs only after a queued engine fact,
---a Fibers deadline, or retained immediate work. `scheduling = "phase"` advances
---on a selected RunService phase under the same bounded turn controls.
function Roblox.attach(fn, opts)
  opts = opts or {}
  local app = Roblox.prepare(fn, opts)
  app:attach(opts)
  return app
end

---Run an attached application and return its checked ScopeResult.
---
---This is convenience sugar for command-style scripts and examples. The caller
---yields on application completion; the Fibers driver itself remains
---non-blocking and is advanced by `attach`.
function Roblox.try_run(fn, opts)
  opts = opts or {}
  local app = Roblox.attach(fn, opts)
  local result, reason = app:await(opts.await_timeout)
  if not result then
    app:close()
    error('Roblox application did not close: ' .. tostring(reason), 2)
  end
  app:close()
  return result
end

---Run an attached Fibers application, raising on structured failure.
function Roblox.run(fn, opts)
  return Roblox.try_run(fn, opts):raise()
end

local function parse_bind_args(scope_or_opts, maybe_opts)
  if type(scope_or_opts) == 'table' and scope_or_opts._fibers_scope == true then
    return scope_or_opts, maybe_opts or {}
  end
  local opts = scope_or_opts or {}
  local scope = Runtime.current_scope and Runtime.current_scope()
  return scope, opts
end

---Cancel a scope when DataModel:BindToClose fires and wait for closure.
---
---Call this from the root fibre. The hidden monitor is an ordinary child Lifetime
---task. The Roblox callback publishes a host fact; the attached application then
---advances through ordinary bounded turns until closure or the declared
---shutdown deadline.
function Roblox.bind_to_close(scope_or_opts, maybe_opts)
  local scope, opts = parse_bind_args(scope_or_opts, maybe_opts)
  local runtime, _, host = current_context({
    runtime = opts.runtime,
    scope = scope,
    host = opts.host,
  })
  local data_model = opts.game or (_G and rawget(_G, 'game')) or game
  if type(data_model) ~= 'table' and type(data_model) ~= 'userdata' then
    error('Roblox.bind_to_close requires game or opts.game', 2)
  end
  if type(data_model.BindToClose) ~= 'function' then
    error('Roblox.bind_to_close requires DataModel:BindToClose', 2)
  end

  local reason = opts.reason or 'Roblox server closing'
  local deadline = opts.deadline or 25
  local shutdown_events, shutdown_feed = External.events(runtime, opts.name or 'roblox-shutdown')

  local monitor = scope:spawn(function()
    local requested_reason = perform(shutdown_events:next_op())
    scope:perform(scope:request_cancel_op(requested_reason or reason))
  end, { name = opts.monitor_name or 'roblox-shutdown-monitor' })

  data_model:BindToClose(function()
    host:deliver(shutdown_feed, reason)
    local settled, wait_reason = host:wait_done(deadline)
    if not settled and type(opts.on_timeout) == 'function' then
      opts.on_timeout(wait_reason, scope, host.application)
    end
  end)

  return {
    monitor = monitor,
    events = shutdown_events,
    reason = reason,
    deadline = deadline,
    application = host.application,
  }
end

return Roblox
