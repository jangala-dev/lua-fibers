-- Single-assignment completion state for deferred host work.

local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local StateMachine = require('fibers.resource.machine')
local Cell = require('fibers.resource.cell')
local ValueSemantics = require('fibers.internal.value_semantics')

local Completion = {}
Completion.__index = Completion
Completion.read_op = Cell.read_op
Completion.transition_op = StateMachine.transition_op
Completion.select_op = Cell.select_op

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

function Completion.new()
  return Facility._state(Facility.identity(setmetatable({}, Completion), Kind),
    { kind = 'pending' }, 'machine', ValueSemantics.trusted, 'Completion state')
end

function Completion:_is_pending() return self._location.value.kind == 'pending' end
function Completion:publish_success_op(...)
  return self:transition_op(Publish, { kind = 'succeeded', values = Facility.pack(...) })
end
function Completion:publish_failure_op(error) return self:transition_op(Publish, { kind = 'failed', error = error }) end
function Completion:publish_cancelled_op(reason) return self:transition_op(Publish, { kind = 'cancelled', reason = reason }) end

function Completion:terminal_op()
  return self:select_op(function(state)
    if state.kind ~= 'pending' then return Op.always(state) end
  end)
end

function Completion:pending_op()
  return self:select_op(function(state)
    if state.kind == 'pending' then return Op.always(true) end
    return Op.never()
  end)
end

function Completion:value_op()
  return self:read_op():map(function(state)
    return state.kind == 'succeeded' and state.values[1] or nil
  end)
end

function Completion:is_terminal_op()
  return self:read_op():map(function(state) return state.kind ~= 'pending' end)
end

function Completion:result_op()
  return self:terminal_op():map(function(state)
    if state.kind == 'succeeded' then
      return unpack_(state.values, 1, state.values.n)
    end
    if state.kind == 'failed' then return nil, state.error end
    return nil, state.reason
  end)
end

function Completion:success_op()
  return self:select_op(function(state)
    if state.kind == 'succeeded' then
      return Op.always(unpack_(state.values, 1, state.values.n))
    end
    if state.kind ~= 'pending' then return Op.never() end
  end)
end

function Completion:failure_op()
  return self:select_op(function(state)
    if state.kind == 'failed' then return Op.always(state.error) end
    if state.kind == 'cancelled' then return Op.always(state.reason) end
    if state.kind == 'succeeded' then return Op.never() end
  end)
end

Completion.Kind = Kind

return Completion
