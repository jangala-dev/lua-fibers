---Roblox host boundary for the embedded Fibers driver.
---
---Generic queueing, wake coalescing and external delivery are supplied by
---`fibers.embed.queue`. Scheduler and BindableEvent capabilities are acquired
---lazily: a manually advanced application needs only a clock and this queue.

local Queue = require('fibers.embed.queue')
local Contract = require('fibers.internal.contract')

local RobloxHost = {}

local HOST_OPTIONS = {
  now = true, task = true, make_event = true, done_event = true,
  on_external_error = true, label = true,
}
RobloxHost.__index = RobloxHost
setmetatable(RobloxHost, { __index = Queue })

local function global_value(name)
  local globals = _G
  return type(globals) == 'table' and rawget(globals, name) or nil
end

local function default_task()
  return global_value('task') or task
end

local function default_instance()
  return global_value('Instance') or Instance
end

local function default_now()
  return os.clock()
end

local function default_make_event()
  local Instance = default_instance()
  if type(Instance) ~= 'table' or type(Instance.new) ~= 'function' then
    error('Roblox host requires Instance.new or opts.make_event', 3)
  end
  return Instance.new('BindableEvent')
end

local function require_task(api)
  if type(api) ~= 'table' then
    error('Roblox host requires the Roblox task library or opts.task', 3)
  end
  for _, name in ipairs({ 'defer', 'delay', 'cancel' }) do
    if type(api[name]) ~= 'function' then
      error('Roblox host task adapter requires task.' .. name, 3)
    end
  end
  return api
end

local function require_event(event, label)
  local event_type = type(event)
  if event_type ~= 'table' and event_type ~= 'userdata' then
    error((label or 'Roblox host event') .. ' must be a BindableEvent-like value', 3)
  end
  local signal = event.Event
  local signal_type = type(signal)
  if
    type(event.Fire) ~= 'function'
    or (signal_type ~= 'table' and signal_type ~= 'userdata')
    or type(signal.Wait) ~= 'function'
  then
    error((label or 'Roblox host event') .. ' requires Fire and Event:Wait', 3)
  end
  return event
end

local function safe_cancel(task_api, token)
  if token ~= nil then pcall(task_api.cancel, token) end
end

local function safe_destroy(event)
  if event and type(event.Destroy) == 'function' then
    pcall(event.Destroy, event)
  end
end

function RobloxHost.is_supported()
  local task_api = default_task()
  local Instance = default_instance()
  if type(task_api) ~= 'table' then
    return false, 'Roblox task library is unavailable'
  end
  if type(Instance) ~= 'table' or type(Instance.new) ~= 'function' then
    return false, 'Roblox Instance.new is unavailable'
  end
  return type(task_api.defer) == 'function'
    and type(task_api.delay) == 'function'
    and type(task_api.cancel) == 'function'
end

function RobloxHost.new(opts)
  opts = Contract.options(opts, HOST_OPTIONS, 'RobloxHost.new options', 2)
  Contract.optional_function(opts.now, 'RobloxHost.new opts.now', 2)
  Contract.optional_function(opts.on_external_error, 'RobloxHost.new opts.on_external_error', 2)
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'RobloxHost.new opts.label', 2) end
  if opts.task ~= nil and opts.task ~= false and type(opts.task) ~= 'table' then
    error('RobloxHost.new opts.task must be a task adapter, false, or nil', 2)
  end
  if opts.make_event ~= nil and opts.make_event ~= false and type(opts.make_event) ~= 'function' then
    error('RobloxHost.new opts.make_event must be a function, false, or nil', 2)
  end
  local self
  self = Queue.new({
    kind = 'roblox',
    family = 'roblox',
    now = opts.now or default_now,
    features = { time = true, external = true, readiness = false, poller = false },
    on_external_error = opts.on_external_error,
    on_done = function(value)
      if self and self._done_event then self._done_event:Fire(value) end
    end,
    label = opts.label,
  })
  self._task = opts.task
  if self._task == nil then self._task = default_task() end
  self._make_event = opts.make_event
  if self._make_event == nil then self._make_event = default_make_event end
  self._done_event = opts.done_event
  if self._done_event ~= nil then
    self._done_event = require_event(self._done_event, 'Roblox done event')
  end
  return setmetatable(self, RobloxHost)
end

function RobloxHost:require_task()
  local task_api = self._task
  if task_api == nil then task_api = default_task() end
  self._task = require_task(task_api)
  return self._task
end

function RobloxHost:_completion_event()
  if self._done_event ~= nil then return self._done_event end
  if type(self._make_event) ~= 'function' then
    error('Roblox completion waiting requires Instance.new or opts.make_event', 2)
  end
  self._done_event = require_event(self._make_event('done'), 'Roblox done event')
  return self._done_event
end

function RobloxHost:supports_interest(interest)
  local kind = interest and interest.external_kind
  if kind == 'readiness' or kind == 'poller' then
    return false, 'Roblox does not drive descriptor readiness interests'
  end
  return true
end

---Standalone blocking is deliberately unsupported for the Roblox host.
function RobloxHost:block()
  return nil, 'roblox-host-is-embedded-use-fibers.roblox'
end


---Wait from a convenience caller or shutdown callback until closure.
function RobloxHost:wait_done(timeout)
  if self._done then return true, self._done_value end
  local task_api = self:require_task()
  local done_event = self:_completion_event()
  if timeout ~= nil then Contract.non_negative_number(timeout, 'RobloxHost:wait_done timeout', 2) end

  local timed_out = false
  local timer
  if timeout ~= nil then
    timer = task_api.delay(timeout, function()
      timed_out = true
      done_event:Fire(false, 'deadline')
    end)
  end
  done_event.Event:Wait()
  safe_cancel(task_api, timer)
  if self._done then return true, self._done_value end
  if timed_out then return false, 'deadline' end
  return false, 'runtime-not-done'
end

function RobloxHost:close()
  if self._closed then return true end
  self:mark_done(self._done_value)
  Queue.close(self)
  local done_event = self._done_event
  self._done_event = nil
  if done_event then
    local task_api = self._task
    if type(task_api) == 'table' and type(task_api.defer) == 'function' then
      task_api.defer(function() safe_destroy(done_event) end)
    else
      safe_destroy(done_event)
    end
  end
  return true
end

return RobloxHost
