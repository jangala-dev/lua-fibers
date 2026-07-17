-- Task: public owned computation.
--
-- A Task is not a second scheduler primitive. It is the standard owned running
-- work abstraction built from the supported resource and lifetime layers. Region
-- admits ownership, Scalar holds completion and cancellation facts, and Effect.spawn starts the fibre after
-- commit.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local perform = require('fibers.perform')
local Scalar = require('fibers.scalar')
local Effect = require('fibers.lifetime.effect')
local Interrupt = require('fibers.internal.interrupt')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.internal.settlement')
local Protected = require('fibers.internal.protected')
local Exit = require('fibers.lifetime.exit')

local unpack_ = table.unpack or unpack
local function pack(...)
  return { _fibers_pack = true, n = select('#', ...), ... }
end

local Task = {}
Task.__index = Task

local RequestCancel = Scalar.transition({
  name = 'task.request_cancel',
  mode = 'update',
  step = function(state, payload)
    if type(state) == 'table' and (state.cancelled or state.requested) then
      return Scalar.Ready.same(false, state.reason)
    end
    local next_state = { requested = true, cancelled = true, reason = payload.reason }
    return Scalar.Ready.write(next_state, true, payload.reason)
  end,
})

local next_id = 0

local function is_pending(v)
  return type(v) == 'table' and v.status == 'pending'
end

local function wait_for_scalar(scalar, pred)
  local dependencies = Op.dependencies(scalar:snapshot_op(), scalar:changed_op(0))
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if pred(s.value) then
        return Op.always(s.value)
      end
      return scalar:changed_op(s.version):and_then(function()
        return loop()
      end, dependencies)
    end, dependencies)
  end
  return loop()
end

function Task.new(fn, name, scope)
  if type(fn) ~= 'function' then
    error('Task.new expects a function', 2)
  end
  next_id = next_id + 1
  local id = 'task-' .. tostring(next_id)
  return setmetatable({
    fn = fn,
    name = name or id,
    completion = Scalar.new({ status = 'pending' }, (name or id) .. '-completion'),
    cancellation = Scalar.new({ requested = false, cancelled = false }, (name or id) .. '-cancellation'),
    interrupt = Interrupt.new((name or id) .. '-interrupt'),
    scope = scope,
    owner = nil,
    owner_version = 0,
    _fibers_obligation_kind = 'task',
    _fibers_id = id,
    _fibers_kind = Ownership.Kind,
    _fibers_settle = Settlement.task_interrupt(),
    _fibers_settle_name = 'task_interrupt',
  }, Task)
end

function Task:_spawn_body(fn)
  local task = self
  return function()
    local rt = Runtime.current()
    if not rt then
      error('task started without a current runtime', 2)
    end
    local results = pack(Protected.pcall(fn, task))
    fn = nil
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
    local completion_write = task.completion:write_op(exit)
    rt:perform(
      task.completion:read_op():and_then(function(v)
        if not is_pending(v) then
          return Op.always(false)
        end
        return completion_write:and_then(function()
          return Op.emit(Effect.scope({
            type = 'task_exit',
            item = task,
            task = task,
            exit = exit,
          })):map(function()
            return true
          end)
        end, false)
      end, Op.dependencies(completion_write)),
      { masked = true }
    )
  end
end

function Task:_start_internal(rt, scope)
  if not rt or type(rt._spawn_committed) ~= 'function' then
    error('Task:_start_internal requires a Runtime', 2)
  end
  local body = self:_spawn_body(self.fn)
  self.fn = nil
  self.scope = nil
  return rt:_spawn_committed(body, self.name, scope)
end

function Task:_spawn_effect()
  -- The start function and scope are consumed by the committed spawn effect.
  -- The Task handle remains a handle to completion/cancellation state; it is
  -- not a long-lived archive of the start closure.
  return Effect.spawn(self:_spawn_body(self.fn), self.name, self._fibers_id, self.scope, self)
end

function Task:owned(settle, opts)
  opts = opts or {}
  opts.role = opts.role or 'task'
  opts.settle_name = opts.settle_name or self._fibers_settle_name or 'task_interrupt'
  return Owned.item(self, settle or self._fibers_settle or Settlement.task_interrupt(), opts)
end

function Task:spawn_effect_op()
  return Op.emit(self:_spawn_effect()):map(function()
    return self
  end)
end

function Task:start_op(region, settle, opts)
  if not region or type(region.admit_op) ~= 'function' then
    error('Task:start_op expects a Region', 2)
  end
  local task = self
  return region:admit_op(task:owned(settle, opts)):and_then(function()
    return task:spawn_effect_op()
  end, false)
end

function Task.spawn_op(region, fn, name)
  local opts = type(name) == 'table' and name or nil
  if opts then
    name = opts.name
  end
  if not region or type(region.admit_op) ~= 'function' then
    error('Task.spawn_op expects a Region', 2)
  end
  local task = Task.new(fn, name)
  if opts and type(opts.scope) == 'function' then
    task.scope = opts.scope(task)
  elseif opts then
    task.scope = opts.scope
  end
  return task:start_op(region, opts and opts.settle or nil, opts)
end

function Task:exit_op()
  return wait_for_scalar(self.completion, Exit.is)
end

function Task:await_op()
  return self:exit_op():wrap(function(exit)
    return Exit.unwrap(exit)
  end)
end

function Task:request_cancel_op(reason)
  return self.cancellation
    :transition_op(RequestCancel, { reason = reason })
    :and_then(function(first, recorded_reason)
      if not first then
        return Op.always(false, recorded_reason)
      end
      return Op.emit(Effect.interrupt(self.interrupt, recorded_reason)):map(function()
        return true, recorded_reason
      end)
    end, false)
end

function Task:cancel_requested_op()
  return wait_for_scalar(self.cancellation, function(v)
    return type(v) == 'table' and (v.cancelled or v.requested)
  end):map(function(v)
    return true, v.reason
  end)
end

function Task:state_op()
  local cancellation_read = self.cancellation:read_op()
  return self.completion:read_op():and_then(function(completion)
    return cancellation_read:map(function(cancel)
      return {
        exited = Exit.is(completion),
        exit = completion,
        cancel_requested = type(cancel) == 'table' and (cancel.cancelled or cancel.requested) or false,
        cancel_reason = type(cancel) == 'table' and cancel.reason or nil,
        task = self,
      }
    end)
  end, Op.dependencies(cancellation_read))
end

function Task:await()
  return perform(self:await_op())
end

function Task:request_cancel(reason)
  return perform(self:request_cancel_op(reason))
end

return Task
