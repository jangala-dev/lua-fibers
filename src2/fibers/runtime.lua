-- fibers/runtime.lua
--
-- Fibres + only-yield-Pulse + fibre-local ctx.

local pulse = require 'fibers.pulse'

local runtime = {
  sched    = nil,
  _current = nil,
  _live    = {},
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

local function init(sched)
  if type(sched) ~= 'table' then error('runtime.init expects a Scheduler', 2) end

  runtime.sched    = sched
  runtime._current = nil
  runtime._live    = {}

  ctx_by_fibre = setmetatable({}, { __mode = 'k' })
end

local function spawn(fn, name)
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end
  local f = Fiber.new(fn, name)
  runtime._live[f] = true
  runtime.sched:schedule(f)
  return f
end

local function main()
  if not runtime.sched then error('runtime not initialised (call init(sched))', 2) end
  while runtime.sched:step() do end
  if next(runtime._live) then
    error('deadlock: no runnable tasks (all fibres appear to be waiting)', 0)
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
  -- state
  runtime = runtime,

  -- types (internal)
  Fiber = Fiber,

  -- API
  init  = init,
  spawn = spawn,
  main  = main,
  ctx   = runtime.ctx,
  current = runtime.current,
}
