-- Task: execution and control capability for a running Lifetime.
--
-- Task contains no custody, cancellation or completion state. Those facts
-- belong to its Lifetime node. Ordinary tasks are created only by
-- Scope:spawn_op; driven domain resources may create a Task view over their own
-- running Lifetime internally.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local perform = require('fibers.perform')
local Effect = require('fibers.effect')
local Protected = require('fibers.protected')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local ScopeOutcome = require('fibers.scope.outcome')
local ScopeResult = ScopeOutcome.Result
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local unpack_ = table.unpack or unpack

local Exit = {}
Exit.__index = Exit

local function exit_pack(...)
  return { n = select('#', ...), ... }
end

local function new_exit(tag, fields)
  fields = fields or {}
  fields.tag = tag
  fields._fibers_exit = true
  return setmetatable(fields, Exit)
end

function Exit.returned(...)
  return new_exit('returned', { values = exit_pack(...) })
end

function Exit.failed(err)
  return new_exit('failed', { error = err })
end

function Exit.cancelled(reason, token)
  return new_exit('cancelled', { reason = reason, token = token })
end

function Exit.is(x)
  return type(x) == 'table' and x._fibers_exit == true
end

function Exit.status(x)
  return Exit.is(x) and x.tag or nil
end

function Exit.unwrap(x)
  if not Exit.is(x) then error('Exit.unwrap expects an Exit value', 2) end
  if x.tag == 'returned' then
    local vals = x.values or { n = 0 }
    return unpack_(vals, 1, vals.n or #vals)
  elseif x.tag == 'cancelled' then
    error(Runtime.cancelled(x.reason, x.token), 0)
  elseif x.tag == 'failed' then
    error(x.error, 0)
  end
  error('unknown task exit tag ' .. tostring(x.tag), 2)
end

function Exit:tostring()
  if self.tag == 'returned' then return 'Exit.returned' end
  if self.tag == 'cancelled' then return 'Exit.cancelled: ' .. tostring(self.reason) end
  if self.tag == 'failed' then return 'Exit.failed: ' .. tostring(self.error) end
  return 'Exit.' .. tostring(self.tag)
end
Exit.__tostring = Exit.tostring

local function pack(...)
  return { n = select('#', ...), ... }
end

local Task = {}
Task.__index = Task

function Task._new(fn, parent_scope, opts)
  if type(fn) ~= 'function' then error('Task creation expects a function', 2) end
  opts = Contract.options(opts, {
    lifetime = true,
    label = true,
    closure = true,
    body_result_owner = true,
  }, 'Task._new options', 2)
  local body_result_owner = opts.body_result_owner or 'task'
  if body_result_owner ~= 'task' and body_result_owner ~= 'scope' then
    error("Task._new body_result_owner must be 'task' or 'scope'", 2)
  end
  local life = opts.lifetime
  if life ~= nil and not Lifetime.is(life) then
    error('Task lifetime must be a Lifetime', 2)
  end
  if not life then
    life = Lifetime.task(fn, {
      label = opts.label,
      closure = Closure.running(Closure.propagation(opts.closure or (parent_scope and parent_scope._lifetime._closure))),
    })
  else
    if life._has_body or life._body ~= nil then
      error('Lifetime already has a body', 2)
    end
    life._body = fn
    life._has_body = true
    local propagation = opts.closure or (parent_scope and parent_scope._lifetime._closure)
    if not life._closure or life._closure.name == 'none' then
      life._closure = Closure.running(Closure.propagation(propagation))
    else
      life._closure = Closure.combine(life._closure, Closure.propagation(propagation))
    end
  end
  return setmetatable({
    _lifetime = life,
    _fibers_task = true,
    _body_result_owner = body_result_owner,
  }, Task)
end

function Task.is(value)
  return type(value) == 'table' and value._fibers_task == true and Lifetime.is(value._lifetime)
end

function Task:lifetime()
  return self._lifetime
end

function Task:label(...)
  if select('#', ...) == 0 then
    return Label.get(self._lifetime)
  end
  Label.set(self._lifetime, select(1, ...), 2)
  return self
end

function Task:diagnostic_label()
  return Label.describe(self._lifetime, self._lifetime._fibers_id or 'task')
end



-- Publish the execution result at the point where the user's Task body exits,
-- not after the Scope sharing this Lifetime has retired its descendants.
-- Publication is strict and exactly once; a second publication is an invariant
-- violation rather than an idempotent compatibility path.
function Task:_publish_protected_body_result(results, runtime)
  local rt = runtime or Runtime.current()
  if not rt then error('task body result published without a current runtime', 2) end
  local exit = ScopeOutcome.protected_exit(Exit, results)
  rt:perform(self._lifetime:publish_body_result_op(exit), { masked = true })
  return exit
end

function Task:_spawn_body(fn)
  local task = self
  return function()
    local rt = Runtime.current()
    if not rt then error('task started without a current runtime', 2) end
    local results = pack(Protected.pcall(fn, task))
    fn = nil
    if task._body_result_owner == 'task' then
      task:_publish_protected_body_result(results, rt)
    else
      local state = rt:perform(task._lifetime._body_result:read_op(), { masked = true })
      if type(state) ~= 'table' or state.status ~= 'done' then
        error('Scope-backed Task returned without publishing its body result', 0)
      end
    end
  end
end

-- The task body remains dormant while spawn is explored. Effect preparation
-- may inspect its availability, but only committed discharge may move it into a
-- runnable fiber frame.
function Task:_spawn_effect()
  local life = self._lifetime
  return Effect.spawn(nil, life._fibers_id, nil, self)
end

function Task:_take_spawn_body(runtime)
  local life = self._lifetime
  if runtime ~= nil and life._runtime ~= runtime then
    error('committed spawn Task belongs to another Runtime', 2)
  end
  local fn = life._body
  if type(fn) ~= 'function' then
    error('committed spawn Task has no dormant body', 2)
  end
  local runnable = self:_spawn_body(fn)
  life._body = nil
  return runnable
end

function Task:spawn_effect_op()
  local task = self
  return Op.emit(self:_spawn_effect()):map(function() return task end)
end

function Task:body_result_op()
  return self._lifetime:body_result_op()
end

-- `body_result_op` observes immediate execution. `await_op` waits for complete
-- Lifetime closure, including children and closure.

function Task:outcome_op()
  return self._lifetime:outcome_op()
end

function Task:await_op()
  return self:outcome_op():wrap(function(result)
    if ScopeResult.is(result) then return result:raise() end
    return result
  end)
end

function Task:request_cancel_op(reason)
  -- A Task is the control capability for the complete running Lifetime, not only
  -- for its current coroutine suspension. Route cancellation through the Scope
  -- view so Closure policy seals admission and propagates the request to retained
  -- descendants even after the user body has already exited. Require lazily to
  -- avoid the Task <-> Scope construction cycle at module load time.
  local Scope = require('fibers.scope')
  return Scope.for_lifetime(self._lifetime):request_cancel_op(reason)
end

function Task:cancel_requested_op()
  return self._lifetime:cancel_requested_op()
end





Direct.install(Task, { 'await', 'request_cancel' })

Task.Exit = Exit
return Task
