-- Task: public owned computation.
--
-- A Task is not a second scheduler primitive. It is the standard owned running
-- work abstraction built from the base kit: Region admits ownership, Cell holds
-- completion and cancellation facts, and Effect.spawn starts the fibre after
-- commit.

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Cell = require('fibers.base.cell')
local Effect = require('fibers.base.effect')
local Interrupt = require('fibers.internal.interrupt')
local Ownership = require('fibers.internal.ownership')
local Protected = require('fibers.kernel.protected')
local Exit = require('fibers.kernel.exit')

local unpack_ = table.unpack or unpack
local function pack(...) return { _fibers_pack = true, n = select('#', ...), ... } end

local Task = {}
Task.__index = Task

local next_id = 0

local function is_pending(v)
  return type(v) == 'table' and v.status == 'pending'
end

local function wait_for_cell(cell, pred)
  local function loop()
    return cell:snapshot_op():and_then(function(s)
      if pred(s.value) then return Op.always(s.value) end
      return cell:changed_op(s.version):and_then(function() return loop() end)
    end)
  end
  return loop()
end

function Task.new(fn, name, frame)
  if type(fn) ~= 'function' then error('Task.new expects a function', 2) end
  next_id = next_id + 1
  local id = 'task-' .. tostring(next_id)
  return setmetatable({
    fn = fn,
    name = name or id,
    completion = Cell.new({ status = 'pending' }, (name or id) .. '-completion'),
    cancellation = Cell.new({ cancelled = false }, (name or id) .. '-cancellation'),
    interrupt = Interrupt.new((name or id) .. '-interrupt'),
    frame = frame,
    owner = nil,
    owner_version = 0,
    _fibers_obligation_kind = 'task',
    _fibers_id = id,
    _fibers_kind = Ownership.Kind,
  }, Task)
end

function Task:_spawn_body()
  local task = self
  return function()
    local rt = Runtime.current()
    if not rt then error('task started without a current runtime', 2) end
    local results = pack(Protected.pcall(task.fn, task))
    local ok = results[1]
    local exit
    if ok then
      exit = Exit.returned(unpack_(results, 2, results.n))
    else
      local err = results[2]
      if Runtime.is_cancelled and Runtime.is_cancelled(err) then
        exit = Exit.cancelled(err.reason, err.token)
      else
        exit = Exit.failed(err)
      end
    end
    rt:perform(task.completion:read_op():and_then(function(v)
      if not is_pending(v) then return Op.always(false) end
      return task.completion:write_op(exit)
    end), { masked = true })
  end
end

function Task:_spawn_effect()
  return Effect.spawn(self:_spawn_body(), self.name, self._fibers_id, self.frame)
end

function Task:start_op(region)
  if not region or type(region.admit_op) ~= 'function' then error('Task:start_op expects a Region', 2) end
  local task = self
  return region:admit_op(task):and_then(function()
    return Op.emit(task:_spawn_effect()):map(function() return task end)
  end)
end

function Task.spawn_op(region, fn, name)
  local opts = type(name) == 'table' and name or nil
  if opts then name = opts.name end
  if not region or type(region.admit_op) ~= 'function' then error('Task.spawn_op expects a Region', 2) end
  local task = Task.new(fn, name)
  if opts and type(opts.frame) == 'function' then task.frame = opts.frame(task) elseif opts then task.frame = opts.frame end
  return task:start_op(region)
end

function Task:exit_op()
  return wait_for_cell(self.completion, Exit.is)
end

function Task:await_op()
  return self:exit_op():wrap(function(exit)
    return Exit.unwrap(exit)
  end)
end

function Task:request_cancel_op(reason)
  return self.cancellation:write_op({ cancelled = true, reason = reason })
    :and_then(function() return Op.emit(Effect.interrupt(self.interrupt, reason)) end)
end

function Task:cancel_requested_op()
  return wait_for_cell(self.cancellation, function(v) return type(v) == 'table' and v.cancelled end):map(function(v)
    return true, v.reason
  end)
end

function Task:state_op()
  return self.completion:read_op():and_then(function(completion)
    return self.cancellation:read_op():map(function(cancel)
      return {
        exited = Exit.is(completion),
        exit = completion,
        cancel_requested = type(cancel) == 'table' and cancel.cancelled or false,
        cancel_reason = type(cancel) == 'table' and cancel.reason or nil,
        task = self,
      }
    end)
  end)
end


return Task
