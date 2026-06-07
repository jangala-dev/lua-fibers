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

M.Op = Op
M.Runtime = Runtime
M.Cell = require('fibers.cell')
M.Channel = require('fibers.channel')
M.Source = require('fibers.source')
M.Region = require('fibers.region')
M.Task = require('fibers.task')
M.Effect = Effect

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

function M.perform(op)
  local rt = Runtime.current()
  if not rt then error('fibers.perform must be called from a running fiber', 2) end
  return rt:perform(op)
end

function M.spawn(fn, name)
  local rt = Runtime.current()
  if not rt then error('fibers.spawn must be called from a running fiber; use fibers.run to start a root fiber', 2) end
  return rt:spawn(fn, name)
end

function M.run(fn, opts)
  opts = opts or {}
  local rt = Runtime.new(opts)
  rt:spawn(function() return fn(rt) end, opts.name or 'root')
  local st = rt:run(opts.run)
  return st, rt
end

-- Existing specialised resources remain available by direct module import.
M.Ledger = require('fibers.resources.ledger')

return M
