-- Convenience entry point for the fibers runtime.
--
-- The low-level public machinery is the base kit:
--   Op, Cell, Channel, Source, Region, Task, Effect.
-- Everything else is kernel infrastructure or ordinary library code built from
-- those nouns.

local M = {}

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Effect = require('fibers.base.effect')
local Protected = require('fibers.kernel.protected')
local Policy = require('fibers.facility.policy')
local Sleep = require('fibers.facility.sleep')
local Flow = require('fibers.facility.flow')
local Stream = require('fibers.facility.stream')
local Host = require('fibers.host')
local Runner = require('fibers.runner')
local Base = require('fibers.base')
local Facility = require('fibers.facility')
local Kernel = require('fibers.kernel')

M.Op = Op
M.Runtime = Runtime
M.Cell = require('fibers.base.cell')
M.Channel = require('fibers.base.channel')
M.Source = require('fibers.base.source')
M.Region = require('fibers.base.region')
M.Lifetime = require('fibers.facility.lifetime')
M.Flow = Flow
M.Stream = Stream
M.sleep_op = Sleep.sleep_op
M.sleep_until_op = Sleep.sleep_until_op
M.Task = require('fibers.base.task')
M.Exit = require('fibers.kernel.exit')
M.Effect = Effect
M.base = Base
M.facility = Facility
M.kernel = Kernel
M.host = Host
M.Runner = Runner
M.policy = Policy

M.clock = M.Source.clock('clock')

M.always = Op.always
M.never = Op.never
M.choice = Op.choice
M.named_choice = Op.named_choice
M.all = Op.all
M.named_all = Op.named_all
M.tensor = Op.tensor
M.after_commit = Effect.after_commit


function M.pcall(fn, ...)
  return Protected.pcall(fn, ...)
end

function M.xpcall(fn, handler, ...)
  return Protected.xpcall(fn, handler, ...)
end

function M.current_runtime()
  return Runtime.current()
end

local function current_frame()
  return Runtime._current_frame and Runtime._current_frame() or nil
end

function M.perform(op)
  local rt = Runtime.current()
  if not rt then error('fibers.perform must be called from a running fiber', 2) end
  local frame = current_frame()
  if frame and type(frame.perform) == 'function' then return frame:perform(op) end
  return rt:perform(op)
end

function M.spawn_raw(fn, name)
  local rt = Runtime.current()
  if not rt then error('fibers.spawn_raw must be called from a running fiber; use fibers.run to start a root fiber', 2) end
  return rt:spawn_raw(fn, name)
end

function M.spawn(fn, name)
  local frame = current_frame()
  if not frame or type(frame.spawn) ~= 'function' then
    error('fibers.spawn requires a launch policy with structured spawning; use fibers.spawn_raw for unstructured fibres', 2)
  end
  return frame:spawn(fn, name)
end

function M.mask(fn, ...)
  if type(fn) ~= 'function' then error('fibers.mask expects a function', 2) end
  local frame = current_frame()
  if not frame then return fn(...) end
  frame.mask_depth = (frame.mask_depth or 0) + 1
  local ok, a, b, c, d, e = Protected.pcall(fn, ...)
  frame.mask_depth = frame.mask_depth - 1
  if not ok then error(a, 0) end
  return a, b, c, d, e
end

M.uninterruptible = M.mask

local function runtime_options(opts, host)
  local rt_opts = {}
  for k, v in pairs(opts or {}) do rt_opts[k] = v end
  rt_opts.host = host
  return rt_opts
end

local function default_host(opts)
  if opts and opts.host then return opts.host end
  local host = Host.pure()
  if opts and opts.now then
    host.now = function(rt) return opts.now(rt) end
  end
  return host
end

function M.launch(policy, fn, opts)
  if type(policy) == 'function' and fn == nil then
    fn, policy, opts = policy, Policy.raw(), {}
  end
  opts = opts or {}
  policy = policy or Policy.raw()
  if type(fn) ~= 'function' then error('fibers.launch expects a function', 2) end
  if type(policy) ~= 'table' or type(policy.enter) ~= 'function' then error('fibers.launch expects a policy', 2) end
  local host = default_host(opts)
  local rt = Runtime.new(runtime_options(opts, host))
  local frame = policy:enter(rt, nil)
  rt:spawn_raw(function()
    if type(policy.run_root) == 'function' then return policy:run_root(frame, fn, rt) end
    return fn(rt)
  end, opts.name or 'root', frame)
  local st = Runner.run(rt, { host = host, run = opts.run, host_options = opts.host_options, max_iterations = opts.max_iterations })
  return st, rt, frame
end

function M.run(fn, opts)
  opts = opts or {}
  local host = default_host(opts)
  local rt = Runtime.new(runtime_options(opts, host))
  rt:spawn_raw(function() return fn(rt) end, opts.name or 'root')
  local st = Runner.run(rt, { host = host, run = opts.run, host_options = opts.host_options, max_iterations = opts.max_iterations })
  return st, rt
end


return M
