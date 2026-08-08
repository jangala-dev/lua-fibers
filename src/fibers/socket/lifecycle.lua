-- Shared transactional lifecycle machine for listener-like socket resources.

local Op = require('fibers.op')
local StateMachine = require('fibers.resource.machine')
local Label = require('fibers.internal.label')
local IOError = require('fibers.io.error')

local Ready = StateMachine.Ready
local Lifecycle = {}

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

Lifecycle.copy = copy

function Lifecycle.wait_for(machine, select)
  return machine:select_op(select)
end

local function transition(name, step)
  return StateMachine.isolated_update(name, step)
end

function Lifecycle.define(spec)
  local prefix = assert(spec.prefix, 'socket lifecycle prefix required')
  local Type = {}
  Type.__index = Type

  local Activate = transition(prefix .. '.activate', function(current, payload)
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

  local StartFailed = transition(prefix .. '.start_failed', function(current, payload)
    if current.kind ~= 'starting' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'stopped',
      address = current.address,
      handle = nil,
      reason = spec.start_failed_reason,
      error = payload.error,
      fatal = payload.fatal == true,
    }
    return Ready.write(next_state, true, next_state)
  end)

  local RequestStop = transition(prefix .. '.request_stop', function(current, payload)
    if current.kind == 'starting' or current.kind == 'active' then
      local next_state = {
        kind = 'stopping',
        address = current.address,
        handle = current.handle,
        reason = payload.reason,
        error = payload.error,
        fatal = payload.fatal == true,
        close_error = nil,
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
      if payload.fatal == true and current.fatal ~= true then
        if next_state == current then
          next_state = copy(current)
        end
        next_state.fatal = true
        changed = true
      end
      if changed then
        return Ready.write(next_state, false, next_state)
      end
    end
    return Ready.same(false, current)
  end)

  local RecordCloseError = transition(prefix .. '.record_close_error', function(current, payload)
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

  local Stopped = transition(prefix .. '.stopped', function(current, payload)
    if current.kind == 'stopped' then
      return Ready.same(false, current)
    end
    local next_state = copy(current)
    next_state.kind = 'stopped'
    next_state.reason = next_state.reason or payload.reason
    if payload.error ~= nil and next_state.error == nil then
      next_state.error = payload.error
    end
    if payload.fatal == true then
      next_state.fatal = true
    end
    return Ready.write(next_state, true, next_state)
  end)

  function Type.new(address)
    local value = Label.attach(setmetatable({
      state = StateMachine.new({
        kind = 'starting',
        address = address,
        handle = nil,
      }),
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
    return self.state:select_op(function(state)
      if state.kind == 'starting' then
        return nil, true
      end
      if state.kind == 'active' then
        return Op.always(state.handle)
      end
      if state.error ~= nil then
        return Op.always(nil, state.error)
      end
      return Op.always(
        nil,
        IOError.closed(spec.error_domain, spec.start_action, {
          reason = state.reason or spec.closed_reason,
          address = state.address,
        })
      )
    end)
  end

  if spec.available then
    function Type:available_op()
      return self.state:select_op(function(state)
        if state.kind == 'starting' or state.kind == 'active' then
          return Op.always(true)
        end
        return nil, false
      end)
    end
  end

  function Type:unavailable_op()
    return self.state:select_op(function(state)
      if state.kind == 'stopping' or state.kind == 'stopped' then
        return Op.always(state)
      end
      return nil, false
    end)
  end

  function Type:terminal_op()
    return self.state:select_op(function(state)
      if state.kind == 'stopped' then
        return Op.always(state)
      end
      return nil, true
    end)
  end

  return Type
end

return Lifecycle
