---Roblox host boundary for the embedded Fibers driver.
---
---Roblox owns scheduling and frame progression. This object supplies monotonic
---time, queues engine observations, and coalesces requests for a later driver
---turn. It never blocks the engine and never enters the Fibers proof engine from
---an RBXScriptSignal callback.
---
---The module is safe to require outside Roblox. Pass `task`, `make_event` and
---`now` implementations to `new` for deterministic tests.

local RobloxHost = {}
RobloxHost.__index = RobloxHost

local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

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
  if token ~= nil then
    pcall(task_api.cancel, token)
  end
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
  opts = opts or {}
  local task_api = require_task(opts.task or default_task())
  local make_event = opts.make_event or default_make_event
  local done_event = require_event(make_event('done'), 'Roblox done event')
  local now = opts.now or default_now

  local self = setmetatable({
    kind = 'roblox',
    name = 'roblox',
    family = 'roblox',
    capabilities = { time = true, external = true },
    _task = task_api,
    _now = now,
    _done_event = done_event,
    _queue = {},
    _queue_head = 1,
    _queue_tail = 0,
    _wake_pending = false,
    _wake_reason = nil,
    _wake_callback = nil,
    _done = false,
    _done_value = nil,
    _closed = false,
    on_external_error = opts.on_external_error,
  }, RobloxHost)

  -- Runtime:now invokes host.now(runtime), not host:now().
  self.now = function(_runtime)
    return now()
  end

  return self
end

---Install the scheduler callback used by an attached Fibers application.
---
---The callback must only arrange a later driver turn. It must not call
---`Runtime:run` or `Runtime:step` recursively from the current engine callback.
function RobloxHost:set_wake_callback(fn)
  if fn ~= nil and type(fn) ~= 'function' then
    error('RobloxHost:set_wake_callback expects a function or nil', 2)
  end
  self._wake_callback = fn
  if fn and self._wake_pending and not self._closed and not self._done then
    fn(self._wake_reason or 'external')
  end
  return fn
end

function RobloxHost:has_pending_wake()
  return self._wake_pending == true
end

function RobloxHost:consume_wake(fallback)
  local reason = self._wake_reason or fallback or 'external'
  self._wake_pending = false
  self._wake_reason = nil
  return reason
end

function RobloxHost:has_external()
  return self._queue_head <= self._queue_tail
end

---Queue work for the next external-driver boundary.
---
---This is the safe route from an RBXScriptSignal callback into Fibers. Queued
---work is drained by `Application:advance` while the runtime is in its external
---phase.
function RobloxHost:enqueue(fn, ...)
  if self._closed or self._done then
    return false, 'host-closed'
  end
  if type(fn) ~= 'function' then
    error('RobloxHost:enqueue expects a function', 2)
  end
  self._queue_tail = self._queue_tail + 1
  self._queue[self._queue_tail] = { fn = fn, args = pack(...) }
  self:wake('external')
  return true
end

---Queue delivery through a runtime-bound ExternalFeed.
function RobloxHost:deliver(feed, ...)
  local args = pack(...)
  return self:enqueue(function()
    feed:set(unpack_(args, 1, args.n))
  end)
end

---Queue clearing through a runtime-bound ExternalFeed.
function RobloxHost:clear(feed, ...)
  local args = pack(...)
  return self:enqueue(function()
    feed:clear(unpack_(args, 1, args.n))
  end)
end

function RobloxHost:_drain_external(limit)
  local count = 0
  while self._queue_head <= self._queue_tail and (not limit or count < limit) do
    local index = self._queue_head
    local item = self._queue[index]
    self._queue[index] = nil
    self._queue_head = index + 1
    if item then
      count = count + 1
      local ok, err = pcall(item.fn, unpack_(item.args, 1, item.args.n))
      if not ok then
        if self.on_external_error then
          self.on_external_error(err)
        end
        error(err, 0)
      end
    end
  end
  if self._queue_head > self._queue_tail then
    self._queue_head, self._queue_tail = 1, 0
  end
  return count
end

---Request one coalesced future driver turn.
function RobloxHost:wake(reason)
  if self._closed or self._done then
    return false
  end
  local already_pending = self._wake_pending
  self._wake_pending = true
  self._wake_reason = self._wake_reason or reason or 'external'
  local callback = self._wake_callback
  if callback and not already_pending then
    local ok, err = pcall(callback, self._wake_reason)
    if not ok then
      if self.on_external_error then
        self.on_external_error(err)
      else
        error(err, 0)
      end
    end
  end
  return true
end

---Standalone blocking is deliberately unsupported for the Roblox host.
---
---Use `fibers.roblox.prepare` for a manually driven embedding or
---`fibers.roblox.attach` for event/phase scheduling.
function RobloxHost:block(_runtime, _waits, _status, _opts)
  return nil, 'roblox-host-is-embedded-use-fibers.roblox'
end

---Mark the embedded application complete and release shutdown waiters.
function RobloxHost:mark_done(value)
  if self._done then
    return value
  end
  self._done = true
  self._done_value = value
  self._done_event:Fire(value)
  return value
end

function RobloxHost:is_done()
  return self._done == true
end

function RobloxHost:done_value()
  return self._done_value
end

---Wait from a convenience caller or shutdown callback until settlement.
function RobloxHost:wait_done(timeout)
  if self._done then
    return true, self._done_value
  end
  timeout = tonumber(timeout)
  if timeout ~= nil and timeout < 0 then
    timeout = 0
  end

  local timed_out = false
  local timer
  if timeout ~= nil then
    timer = self._task.delay(timeout, function()
      timed_out = true
      self._done_event:Fire(false, 'deadline')
    end)
  end
  self._done_event.Event:Wait()
  safe_cancel(self._task, timer)
  if self._done then
    return true, self._done_value
  end
  if timed_out then
    return false, 'deadline'
  end
  return false, 'runtime-not-done'
end

function RobloxHost:close()
  if self._closed then
    return true
  end
  self._closed = true
  self._wake_callback = nil
  self:mark_done(self._done_value)
  self._queue = {}
  self._queue_head, self._queue_tail = 1, 0

  -- A waiter may have just resumed from mark_done. Delay destruction until that
  -- resumption point has completed.
  self._task.defer(function()
    safe_destroy(self._done_event)
  end)
  return true
end

return RobloxHost
