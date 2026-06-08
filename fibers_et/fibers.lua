-- Convenience entry point for the fibers runtime.
--
-- The low-level public machinery is the base kit:
--   Op, Cell, Channel, Source, Region, Task, Effect.
-- Everything else is kernel infrastructure or ordinary library code built from
-- those nouns.

local M = {}

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Effect = require('fibers.effect')
local Protected = require('fibers.protected')
local Policy = require('fibers.policy')

M.Op = Op
M.Runtime = Runtime
M.Cell = require('fibers.cell')
M.Channel = require('fibers.channel')
M.Source = require('fibers.source')
M.Region = require('fibers.region')
M.Lifetime = require('fibers.lifetime')
M.Task = require('fibers.task')
M.Effect = Effect
M.policy = Policy

M.clock = M.Source.clock('clock')

M.always = Op.always
M.never = Op.never
M.choice = Op.choice
M.all = Op.all
M.tensor = Op.tensor
M.after_commit = Effect.after_commit
M.emit = Effect.after_commit


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

function M.launch(policy, fn, opts)
  if type(policy) == 'function' and fn == nil then
    fn, policy, opts = policy, Policy.raw(), {}
  end
  opts = opts or {}
  policy = policy or Policy.raw()
  if type(fn) ~= 'function' then error('fibers.launch expects a function', 2) end
  if type(policy) ~= 'table' or type(policy.enter) ~= 'function' then error('fibers.launch expects a policy', 2) end
  local rt = Runtime.new(opts)
  local frame = policy:enter(rt, nil)
  rt:spawn_raw(function()
    if type(policy.run_root) == 'function' then return policy:run_root(frame, fn, rt) end
    return fn(rt)
  end, opts.name or 'root', frame)
  local st = rt:run(opts.run)
  return st, rt, frame
end

function M.run(fn, opts)
  opts = opts or {}
  local rt = Runtime.new(opts)
  rt:spawn_raw(function() return fn(rt) end, opts.name or 'root')
  local st = rt:run(opts.run)
  return st, rt
end

-- Existing specialised resources remain available by direct module import.
M.Ledger = require('fibers.resources.ledger')

return M
