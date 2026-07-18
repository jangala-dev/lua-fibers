-- Single-assignment completion state for deferred host work.
--
-- Completion is intentionally internal.  Facilities may expose domain-shaped
-- result options while sharing one tested terminal-state protocol.

local Op = require('fibers.op')
local Scalar = require('fibers.scalar')

local Completion = {}
Completion.__index = Completion
local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local Ready = Scalar.Ready
local next_id = 0

local publish = Scalar.transition({
  name = 'completion.publish',
  mode = 'update',
  accepts_supply = false,
  supplies = 'none',
  step = function(current, payload)
    if current.kind ~= 'pending' then
      return Ready.same(nil, {
        kind = 'completion_already_terminal',
        current = current,
        attempted = payload.state,
      })
    end
    return Ready.write(payload.state, true)
  end,
})

local function terminal_option(self, selector)
  local function loop()
    return self.state:snapshot_op():and_then(function(snapshot)
      local state = snapshot.value
      local option = selector(state)
      if option then
        return option
      end
      return self.state:changed_op(snapshot.version):and_then(loop)
    end)
  end
  return loop()
end

function Completion.new(name)
  next_id = next_id + 1
  local id = 'completion-' .. tostring(next_id)
  return setmetatable({
    name = name or id,
    _fibers_id = id,
    state = Scalar.machine({ kind = 'pending' }, (name or id) .. ':state'),
  }, Completion)
end

function Completion:is_pending()
  return self.state.value.kind == 'pending'
end

function Completion:state_value()
  return self.state.value
end

function Completion:publish_success_op(...)
  return self.state:transition_op(publish, {
    state = { kind = 'succeeded', values = pack(...) },
  })
end

function Completion:publish_failure_op(err)
  return self.state:transition_op(publish, {
    state = { kind = 'failed', error = err },
  })
end

function Completion:publish_cancelled_op(reason)
  return self.state:transition_op(publish, {
    state = { kind = 'cancelled', reason = reason },
  })
end

function Completion:terminal_op()
  return terminal_option(self, function(state)
    if state.kind ~= 'pending' then
      return Op.always(state)
    end
  end)
end

function Completion:pending_op()
  return self.state:read_op():and_then(function(state)
    if state.kind == 'pending' then
      return Op.always(true)
    end
    return Op.never()
  end)
end

function Completion:result_op()
  return self:terminal_op():map(function(state)
    if state.kind == 'succeeded' then
      local values = state.values or pack(state.value)
      return unpack_(values, 1, values.n)
    end
    if state.kind == 'failed' then
      return nil, state.error
    end
    return nil, state.reason
  end)
end

function Completion:success_op()
  return terminal_option(self, function(state)
    if state.kind == 'succeeded' then
      local values = state.values or pack(state.value)
      return Op.always(unpack_(values, 1, values.n))
    elseif state.kind ~= 'pending' then
      return Op.never()
    end
  end)
end

function Completion:failure_op()
  return terminal_option(self, function(state)
    if state.kind == 'failed' then
      return Op.always(state.error)
    elseif state.kind == 'cancelled' then
      return Op.always(state.reason)
    elseif state.kind == 'succeeded' then
      return Op.never()
    end
  end)
end

return Completion
