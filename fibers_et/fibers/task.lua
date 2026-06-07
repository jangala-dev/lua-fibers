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
local Ownership = require('fibers.internal.ownership')

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

function Task.new(fn, name)
  if type(fn) ~= 'function' then error('Task.new expects a function', 2) end
  next_id = next_id + 1
  local id = 'task-' .. tostring(next_id)
  return setmetatable({
    fn = fn,
    name = name or id,
    completion = Cell.new({ status = 'pending', _fibers_value = true }, (name or id) .. '-completion'),
    cancellation = Cell.new({ cancelled = false, _fibers_value = true }, (name or id) .. '-cancellation'),
    owner = nil,
    owner_version = 0,
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
    local results = { pcall(task.fn, task) }
    local ok = table.remove(results, 1)
    local report
    if ok then
      report = { status = 'ok', value = pack_return(results), _fibers_value = true }
    else
      report = { status = 'failed', error = results[1], _fibers_value = true }
    end
    rt:perform(task.completion:modify_when_op(
      function(v) return type(v) == 'table' and v.status == 'pending' end,
      function() return report end
    ))
  end
end

function Task:_spawn_effect()
  return Effect.spawn(self:_spawn_body(), self.name, self._fibers_id)
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

function Task:cancel_op(a, b)
  local OpModule, reason
  if is_op_module(a) then OpModule, reason = a, b else OpModule, reason = DefaultOp, a end
  return self.cancellation:set_op(OpModule, { cancelled = true, reason = reason, _fibers_value = true })
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

return Task
