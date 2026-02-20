-- fibers/runtime.lua
--
-- Fibres + only-yield-Pulse + fibre-local ctx.
-- Runtime-owned timers + optional Pulse-only poller.
--
-- Policy: consult the poller only when there are no runnable tasks.

local pulse = require 'fibers.pulse'
local time  = require 'fibers.utils.time'
local timer = require 'fibers.timer'

local runtime = {
  sched    = nil,
  _current = nil,
  _live    = {},

  -- event kernel
  _now_fn    = nil,
  _block_fn  = nil,
  maxsleep   = 10,

  timers     = nil,
  poller     = nil,  -- optional Pulse-only poller
}

local ctx_by_fibre = setmetatable({}, { __mode = 'k' })

local Fiber = {}
Fiber.__index = Fiber

function Fiber.new(fn, name)
  return setmetatable({
    co = coroutine.create(fn),
    name = name or '<fibre>',
    _queued = false,
    _waiting_pulse = nil,
  }, Fiber)
end

function Fiber:run(_)
  local saved = runtime._current
  runtime._current = self

  local ok, yielded = coroutine.resume(self.co)

  runtime._current = saved

  if not ok then
    runtime._live[self] = nil
    ctx_by_fibre[self] = nil -- drop fibre-local ctx on crash
    error(('fibre %s crashed: %s'):format(self.name, tostring(yielded)), 0)
  end

  if coroutine.status(self.co) == 'dead' then
    runtime._live[self] = nil
    return
  end

  if type(yielded) ~= 'table' or type(yielded.subscribe) ~= 'function' then
    runtime._live[self] = nil
    error(('fibre %s yielded an invalid object (expected Pulse)'):format(self.name), 0)
  end

  yielded:subscribe(self)
end

local function init(sched, opts)
  if type(sched) ~= 'table' then error('runtime.init expects a Scheduler', 2) end
  opts = opts or {}

  runtime.sched    = sched
  runtime._current = nil
  runtime._live    = {}

  ctx_by_fibre = setmetatable({}, { __mode = 'k' })

  runtime._now_fn   = opts.now   or time.monotonic
  runtime._block_fn = opts.block or time._block
  runtime.maxsleep  = (opts.maxsleep ~= nil) and opts.maxsleep or 10

  local now_ = runtime._now_fn()
  runtime.timers = timer.new(now_)

  -- Optional poller can be injected here or set later.
  runtime.poller = opts.poller or nil
end

local function now()
  if not runtime._now_fn then
    error('runtime not initialised (call init(sched))', 2)
  end
  return runtime._now_fn()
end

local function timer_at(t_abs, waker)
  if not runtime.timers then
    error('runtime not initialised (call init(sched))', 2)
  end
  return runtime.timers:add_absolute(t_abs, waker)
end

local function timer_cancel(handle)
  if runtime.timers then
    runtime.timers:cancel(handle)
  end
end

local function next_timer_time()
  if not runtime.timers then
    return math.huge
  end
  return runtime.timers:next_entry_time()
end

-- --------------------------------------------------------------------------
-- Poller integration (Pulse-only)
-- --------------------------------------------------------------------------

local function set_poller(p)
  runtime.poller = p
end

local function poller_has_watchers()
  local p = runtime.poller
  return p ~= nil and p:has_watchers() or false
end

local function poller_watch(fd, dir, waker)
  local p = runtime.poller
  if not p then
    error('no poller installed', 2)
  end
  return p:watch(fd, dir, waker)
end

local function poller_cancel(handle)
  local p = runtime.poller
  if p and handle then
    p:cancel(handle)
  end
end

-- --------------------------------------------------------------------------
-- Source servicing and idle waiting
-- --------------------------------------------------------------------------

local function spawn(fn, name)
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end
  local f = Fiber.new(fn, name)
  runtime._live[f] = true
  runtime.sched:schedule(f)
  return f
end

local function queue_empty()
  local s = runtime.sched
  return (s.head > s.tail)
end

-- Run one generation: execute tasks that were runnable at slice start.
local function run_generation()
  local s = runtime.sched
  local boundary = s.tail  -- snapshot: tasks enqueued during the slice run next slice

  while s.head <= boundary do
    -- step() may return false if the queue empties early (and may reset head/tail).
    if not s:step() then
      break
    end
  end
end

-- Service external sources once per slice / idle transition.
local function service_sources()
  -- Timers first.
  if runtime.timers then
    runtime.timers:advance(now())
  end

  -- Non-blocking poller drain (Pulse-only).
  local p = runtime.poller
  if p and p.poll and poller_has_watchers() then
    p:poll(0)
  end
end

local function main()
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end

  while true do
    -- Slice boundary work: turn external readiness into runnable fibres.
    service_sources()

    if not queue_empty() then
      -- Run exactly one generation, then loop (next iteration is the next slice).
      run_generation()

    else
      -- Idle path: nothing runnable.
      if not next(runtime._live) then
        return
      end

      local tnext       = next_timer_time()
      local have_poller = poller_has_watchers()

      if (tnext == math.huge) and (not have_poller) then
        error('deadlock: no runnable tasks and no pending timers/poller watchers (all fibres appear to be waiting)', 0)
      end

      local tnow = now()
      local timeout = (tnext == math.huge) and runtime.maxsleep or (tnext - tnow)
      if timeout < 0 then timeout = 0 end
      if runtime.maxsleep and timeout > runtime.maxsleep then
        timeout = runtime.maxsleep
      end

      local p = runtime.poller
      if p and p.poll and have_poller then
        local timeout_ms = math.floor(timeout * 1e3 + 0.5)
        p:poll(timeout_ms)
      else
        runtime._block_fn(timeout)
      end
      -- After blocking, loop repeats: service_sources() will observe and enqueue wake-ups.
    end
  end
end

function runtime.ctx()
  local f = runtime._current
  if not f then error('runtime.ctx must be called from inside a fibre', 2) end

  local ctx = ctx_by_fibre[f]
  if not ctx then
    ctx = {
      in_perform = false,
      select_top = nil,
      waker      = pulse.new(runtime.sched),
    }
    ctx_by_fibre[f] = ctx
  end
  return ctx
end

function runtime.current()
  return runtime._current
end

return {
  -- state (retained for existing users such as Channel.new)
  runtime = runtime,

  -- types (internal)
  Fiber = Fiber,

  -- API
  init    = init,
  spawn   = spawn,
  main    = main,
  ctx     = runtime.ctx,
  current = runtime.current,

  -- event kernel API (for tickets)
  now             = now,
  service_sources = service_sources,

  timer_at        = timer_at,
  timer_cancel    = timer_cancel,
  next_timer_time = next_timer_time,

  -- poller API (for tickets / setup)
  set_poller          = set_poller,
  poller_watch         = poller_watch,
  poller_cancel        = poller_cancel,
  poller_has_watchers  = poller_has_watchers,
}
