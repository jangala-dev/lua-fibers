-- Single-assignment completion state for deferred host work.

local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')

local Completion = {}
Completion.__index = Completion

local Kind = Facility.kind('completion')
local Ready = StateMachine.Ready
local unpack_ = table.unpack or unpack

local Publish = StateMachine.isolated_update('completion.publish', function(current, state)
  if current.kind ~= 'pending' then
    return Ready.same(nil, {
      kind = 'completion_already_terminal',
      current = current,
      attempted = state,
    })
  end
  return Ready.write(state, true)
end)

function Completion.new(name)
  local completion = Facility.identity(setmetatable({}, Completion), Kind, name)
  completion.state = StateMachine.new({ kind = 'pending' }, completion.name .. ':state')
  return completion
end

function Completion:is_pending()
  return self.state.value.kind == 'pending'
end

function Completion:state_value()
  return self.state.value
end

function Completion:publish_success_op(...)
  return self.state:transition_op(Publish, { kind = 'succeeded', values = Op._pack(...) })
end

function Completion:publish_failure_op(error)
  return self.state:transition_op(Publish, { kind = 'failed', error = error })
end

function Completion:publish_cancelled_op(reason)
  return self.state:transition_op(Publish, { kind = 'cancelled', reason = reason })
end

function Completion:terminal_op()
  return self.state:select_op(function(state)
    if state.kind ~= 'pending' then
      return Op.always(state)
    end
  end)
end

function Completion:pending_op()
  return self.state:select_op(function(state)
    if state.kind == 'pending' then
      return Op.always(true)
    end
    return Op.never()
  end)
end

function Completion:result_op()
  return self:terminal_op():map(function(state)
    if state.kind == 'succeeded' then
      return unpack_(state.values, 1, state.values.n)
    end
    if state.kind == 'failed' then
      return nil, state.error
    end
    return nil, state.reason
  end)
end

function Completion:success_op()
  return self.state:select_op(function(state)
    if state.kind == 'succeeded' then
      return Op.always(unpack_(state.values, 1, state.values.n))
    end
    if state.kind ~= 'pending' then
      return Op.never()
    end
  end)
end

function Completion:failure_op()
  return self.state:select_op(function(state)
    if state.kind == 'failed' then
      return Op.always(state.error)
    end
    if state.kind == 'cancelled' then
      return Op.always(state.reason)
    end
    if state.kind == 'succeeded' then
      return Op.never()
    end
  end)
end

Completion.Kind = Kind

return Completion
