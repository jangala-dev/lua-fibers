-- Task: public owned computation.
--
-- A Task is not a second scheduler primitive.  It is the standard owned running
-- work abstraction built from the base kit: Region admits ownership, Cell holds
-- completion and cancellation facts, and Effect.spawn starts the fibre after
-- commit.

local DefaultOp = require('fibers.op')
local Runtime = require('fibers.runtime')
local Cell = require('fibers.cell')
local Effect = require('fibers.effect')
local Interrupt = require('fibers.interrupt')
local Ownership = require('fibers.internal.ownership')
local Protected = require('fibers.protected')

local unpack_ = table.unpack or unpack

local Task = {}
Task.__index = Task

local next_id = 0

local function is_op_module(x)
  return type(x) == 'table' and type(x._resource) == 'function'
end

local function pack_return(results)
  if #results <= 1 then return results[1] end
  return { n = #results, unpack_(results) }
end

local function status_done(v)
  return type(v) == 'table' and v.status ~= 'pending'
end

function Task.new(fn, name, frame)
  if type(fn) ~= 'function' then error('Task.new expects a function', 2) end
  next_id = next_id + 1
  local id = 'task-' .. tostring(next_id)
  return setmetatable({
    fn = fn,
    name = name or id,
    completion = Cell.new({ status = 'pending', _fibers_value = true }, (name or id) .. '-completion'),
    cancellation = Cell.new({ cancelled = false, _fibers_value = true }, (name or id) .. '-cancellation'),
    interrupt = Interrupt.new((name or id) .. '-interrupt'),
    frame = frame,
    owner = nil,
    owner_version = 0,
    _fibers_obligation_kind = 'task',
    _fibers_id = id,
    _fibers_kind = Ownership.Kind,
    _fibers_value = true,
  }, Task)
end

function Task:_spawn_body()
  local task = self
  return function()
    local rt = Runtime.current()
    if not rt then error('task started without a current runtime', 2) end
    local results = { Protected.pcall(task.fn, task) }
    local ok = table.remove(results, 1)
    local report
    if ok then
      report = { status = 'ok', value = pack_return(results), _fibers_value = true }
    else
      local err = results[1]
      if Runtime.is_cancelled and Runtime.is_cancelled(err) then
        report = { status = 'cancelled', reason = err.reason, _fibers_value = true }
      else
        report = { status = 'failed', error = err, _fibers_value = true }
      end
    end
    rt:perform(task.completion:modify_when_op(
      function(v) return type(v) == 'table' and v.status == 'pending' end,
      function() return report end
    ), { masked = true })
  end
end

function Task:_spawn_effect()
  return Effect.spawn(self:_spawn_body(), self.name, self._fibers_id, self.frame)
end


function Task.spawn_op(a, b, c, d)
  local OpModule, region, fn, name
  if is_op_module(a) then OpModule, region, fn, name = a, b, c, d else OpModule, region, fn, name = DefaultOp, a, b, c end
  local opts = type(name) == 'table' and name or nil
  if opts then name = opts.name end
  if not region or type(region.admit_op) ~= 'function' then error('Task.spawn_op expects a Region', 2) end
  local task = Task.new(fn, name)
  if opts and type(opts.frame) == 'function' then task.frame = opts.frame(task) elseif opts then task.frame = opts.frame end
  return region:admit_op(OpModule, task):and_then(function()
    return OpModule.emit(task:_spawn_effect()):map(function() return task end)
  end)
end

function Task:join_op(OpModule)
  OpModule = is_op_module(OpModule) and OpModule or DefaultOp
  return self.completion:wait_op(OpModule, status_done):map(function(report)
    return report.status, report.value or report.error or report.reason, report
  end)
end

function Task:peek_op(OpModule)
  OpModule = is_op_module(OpModule) and OpModule or DefaultOp
  return self.completion:get_op(OpModule):map(function(report)
    return status_done(report), report
  end)
end

function Task:cancel_op(a, b, c)
  local OpModule, region, reason
  if is_op_module(a) then
    OpModule = a
    if type(b) == 'table' and type(b.owns_op) == 'function' then region, reason = b, c else reason = b end
  else
    OpModule = DefaultOp
    if type(a) == 'table' and type(a.owns_op) == 'function' then region, reason = a, b else reason = a end
  end

  local set_cancel = function()
    return self.cancellation:set_op(OpModule, { cancelled = true, reason = reason, _fibers_value = true })
      :and_then(function() return OpModule.emit(Effect.interrupt(self.interrupt, reason)) end)
  end

  if not region then return set_cancel() end
  return region:owns_op(OpModule, self):and_then(function(owns)
    if not owns then return OpModule.never() end
    return set_cancel()
  end)
end

function Task:cancelled_op(OpModule)
  OpModule = is_op_module(OpModule) and OpModule or DefaultOp
  return self.cancellation:wait_op(OpModule, function(v) return type(v) == 'table' and v.cancelled end):map(function(v)
    return true, v.reason
  end)
end

function Task:check_cancelled_op(OpModule)
  OpModule = is_op_module(OpModule) and OpModule or DefaultOp
  return self.cancellation:get_op(OpModule):map(function(v)
    return type(v) == 'table' and v.cancelled or false, type(v) == 'table' and v.reason or nil
  end)
end

function Task:is_done()
  return status_done(self.completion.value)
end


function Task:_fibers_can_settle(_ctx, _owner)
  return self:is_done()
end

return Task
