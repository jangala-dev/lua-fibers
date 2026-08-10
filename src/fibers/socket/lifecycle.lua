-- Shared transactional lifecycle machine for listener-like socket resources.

local StateMachine = require('fibers.resource.machine')
local Label = require('fibers.internal.label')
local IOError = require('fibers.io.error')
local TrustedState = require('fibers.internal.trusted_state')

local Ready, Wait = StateMachine.Ready, StateMachine.Wait
local Lifecycle = {}

local function copy(value)
  local out = {}
  for key, item in pairs(value) do
    out[key] = item
  end
  return out
end

Lifecycle.copy = copy

function Lifecycle.define(spec)
  local prefix = assert(spec.prefix, 'socket lifecycle prefix required')
  local Type = {}
  Type.__index = Type

  local Activate = StateMachine.isolated_update(prefix .. '.activate', function(current, payload)
    if current.kind ~= 'starting' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'active',
      address = payload.address or current.address,
      handle = payload.handle,
    }
    return Ready.write(next_state, true, next_state)
  end)

  local StartFailed = StateMachine.isolated_update(prefix .. '.start_failed', function(current, payload)
    if current.kind ~= 'starting' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'stopped',
      address = current.address,
      reason = spec.start_failed_reason,
      error = payload.error,
      fatal = payload.fatal,
    }
    return Ready.write(next_state, true, next_state)
  end)

  local RequestStop = StateMachine.isolated_update(prefix .. '.request_stop', function(current, payload)
    if current.kind == 'starting' or current.kind == 'active' then
      local next_state = {
        kind = 'stopping',
        address = current.address,
        handle = current.handle,
        reason = payload.reason,
        error = payload.error,
        fatal = payload.fatal,
      }
      return Ready.write(next_state, true, next_state)
    end
    if current.kind == 'stopping' or current.kind == 'stopped' then
      local next_state = current
      local changed = false
      if payload.error ~= nil and current.error == nil then
        next_state = copy(current)
        next_state.error = payload.error
        changed = true
      end
      if payload.fatal and not current.fatal then
        if next_state == current then next_state = copy(current) end
        next_state.fatal = true
        changed = true
      end
      if changed then return Ready.write(next_state, false, next_state) end
    end
    return Ready.same(false, current)
  end)

  local RecordCloseError = StateMachine.isolated_update(prefix .. '.record_close_error', function(current, payload)
    if current.kind ~= 'stopping' and current.kind ~= 'stopped' then
      return Ready.same(false, current)
    end
    if current.close_error ~= nil then
      return Ready.same(false, current)
    end
    local next_state = copy(current)
    next_state.close_error = payload.error
    next_state.fatal = true
    return Ready.write(next_state, true, next_state)
  end)

  local Stopped = StateMachine.isolated_update(prefix .. '.stopped', function(current, payload)
    if current.kind == 'stopped' then
      return Ready.same(false, current)
    end
    local next_state = copy(current)
    next_state.kind = 'stopped'
    next_state.reason = next_state.reason or payload.reason
    if payload.error ~= nil and next_state.error == nil then next_state.error = payload.error end
    if payload.fatal then next_state.fatal = true end
    return Ready.write(next_state, true, next_state)
  end)

  local StartResult = StateMachine.isolated_query(prefix .. '.start_result', function(state)
    if state.kind == 'starting' then return Wait end
    if state.kind == 'active' then return Ready.same(state.handle) end
    if state.error ~= nil then return Ready.same(nil, state.error) end
    return Ready.same(nil, IOError.closed(spec.error_domain, spec.start_action, {
      reason = state.reason or spec.closed_reason,
      address = state.address,
    }))
  end)

  local Address = StateMachine.isolated_query(prefix .. '.address', function(state)
    if state.kind == 'starting' then return Wait end
    return Ready.same(state.address)
  end)

  local Available = StateMachine.isolated_query(prefix .. '.available', function(state)
    if state.kind == 'starting' or state.kind == 'active' then return Ready.same(true) end
    return Wait
  end)

  local Unavailable = StateMachine.isolated_query(prefix .. '.unavailable', function(state)
    if state.kind == 'stopping' or state.kind == 'stopped' then return Ready.same(state) end
    return Wait
  end)

  local Terminal = StateMachine.isolated_query(prefix .. '.terminal', function(state)
    if state.kind == 'stopped' then return Ready.same(state) end
    return Wait
  end)

  function Type.new(address)
    local value = Label.attach(setmetatable({
      state = TrustedState.machine({ kind = 'starting', address = address }),
    }, Type))
    Label.child(value.state, value, 'lifecycle')
    return value
  end

  function Type:activate_op(handle, address)
    return self.state:transition_op(Activate, { handle = handle, address = address })
  end

  function Type:start_failed_op(err, fatal)
    return self.state:transition_op(StartFailed, { error = err, fatal = fatal == true })
  end

  function Type:request_stop_op(reason, err, fatal)
    return self.state:transition_op(RequestStop, {
      reason = reason,
      error = err,
      fatal = fatal == true,
    })
  end

  function Type:record_close_error_op(err)
    return self.state:transition_op(RecordCloseError, { error = err })
  end

  function Type:stopped_op(reason, err, fatal)
    return self.state:transition_op(Stopped, {
      reason = reason,
      error = err,
      fatal = fatal == true,
    })
  end

  function Type:start_result_op()
    return self.state:transition_op(StartResult)
  end

  function Type:address_op()
    return self.state:transition_op(Address)
  end

  function Type:available_op()
    return self.state:transition_op(Available)
  end

  function Type:unavailable_op()
    return self.state:transition_op(Unavailable)
  end

  function Type:terminal_op()
    return self.state:transition_op(Terminal)
  end

  return Type
end

return Lifecycle
