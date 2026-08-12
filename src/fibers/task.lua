-- Task: execution and control capability for a running Lifetime.
--
-- Task contains no custody, cancellation or completion state. Those facts
-- belong to its Lifetime node. Ordinary tasks are created only by
-- Scope:spawn_op; driven domain resources may create a Task view over their own
-- running Lifetime internally.

local Runtime = require('fibers.runtime')
local perform = require('fibers.perform')
local Completion = require('fibers.resource.completion')
local Protected = require('fibers.protected')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local ScopeOutcome = require('fibers.scope.outcome')
local ScopeResult = ScopeOutcome.Result
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

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

local Task = {}
Task.__index = Task

local function execution(task) return task._lifetime:_scope_role(false) end

function Task._new(fn, parent_scope, opts)
  if type(fn) ~= 'function' then error('Task creation expects a function', 2) end
  local life = opts.lifetime
  local execution_kind = opts.execution_kind or 'task'
  if not life then
    life = Lifetime.new({
      label = opts.label,
      role = 'task',
      closure = Closure.running(),
    })
  elseif life:_task() ~= nil then
    error('Lifetime already has a Task view', 2)
  elseif not life._protocol or life._protocol.name == 'none' then
    life._protocol = Closure.protocol(Closure.running(), 'Task running protocol')
  end
  local inherited = parent_scope and parent_scope._role and parent_scope._role.policy or nil
  local scope_role = life:_scope_role(true)
  scope_role.policy = Closure._merge_policy(scope_role.policy,
    Closure._merge_policy(inherited, Closure.policy(opts.closure)))
  scope_role.execution_kind = execution_kind
  scope_role.body_result = Completion.new():label((opts.label or 'task') .. '-body-result')
  local task = setmetatable({ _lifetime = life, _fibers_task = true, _body = fn }, Task)
  life:_attach_task(task)
  Label.child(scope_role.body_result, life, 'body-result')
  return task
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



-- Admission is the semantic birth of a running Task.  The LifetimeStore
-- activates body-bearing Lifetimes only after the complete admission commit has
-- installed custody and bound every admitted node to the Runtime.
function Task:_activate_committed(runtime)
  local life = self._lifetime
  if runtime ~= nil and life._runtime ~= runtime then
    error('committed Task activation belongs to another Runtime', 2)
  end
  local fn = self._body
  if type(fn) ~= 'function' then error('committed Task activation has no dormant body', 2) end
  local task = self
  self._body = nil
  return runtime:_spawn_committed(function()
    local rt = Runtime.current()
    if not rt then error('task started without a current runtime', 2) end
    Protected.pcall(fn, task)
    fn = nil
    local state = rt:perform(execution(task).body_result:read_op(), { masked = true })
    if type(state) ~= 'table' or state.kind == 'pending' then
      error('Scope-backed Task returned without publishing its body result', 0)
    end
  end, nil, self)
end

function Task:body_result_op()
  return execution(self).body_result:success_op()
end

-- `body_result_op` observes immediate execution. `outcome_op` observes complete
-- Lifetime closure, including children and closure. `await` is the participant-
-- level convenience which raises a failed structured Scope result; there is no
-- `await_op` because raising after a later causal observation is not one Option.

function Task:outcome_op()
  return self._lifetime:outcome_op()
end

function Task:await()
  local result = perform(self:outcome_op())
  if ScopeResult.is(result) then return result:raise() end
  return result
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





Direct.install(Task, { 'request_cancel' })

Task.Exit = Exit
return Task
