-- Explicit transactional lifecycle resource for socket listeners.

local Op = require('fibers.op')
local Scalar = require('fibers.scalar')
local HostError = require('fibers.host.error')
local Common = require('fibers.internal.socket.lifecycle')

local Ready = Scalar.Ready
local copy = Common.copy
local wait_for = Common.wait_for

local Listener = {}
Listener.__index = Listener

local Activate = Scalar.transition({
  name = 'socket.listener.activate',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
    if current.kind ~= 'starting' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'active',
      address = payload.address or current.address,
      handle = payload.handle,
    }
    return Ready.write(next_state, true, next_state)
  end,
})

local StartFailed = Scalar.transition({
  name = 'socket.listener.start_failed',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
    if current.kind ~= 'starting' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'stopped',
      address = current.address,
      handle = nil,
      reason = 'listener start failed',
      error = payload.error,
      fatal = payload.fatal == true,
    }
    return Ready.write(next_state, true, next_state)
  end,
})

local RequestStop = Scalar.transition({
  name = 'socket.listener.request_stop',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
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
      local needs_write = false
      if payload.error ~= nil and current.error == nil then
        next_state = copy(current)
        next_state.error = payload.error
        needs_write = true
      end
      if payload.fatal == true and current.fatal ~= true then
        if next_state == current then
          next_state = copy(current)
        end
        next_state.fatal = true
        needs_write = true
      end
      if needs_write then
        return Ready.write(next_state, false, next_state)
      end
    end

    return Ready.same(false, current)
  end,
})

local RecordCloseError = Scalar.transition({
  name = 'socket.listener.record_close_error',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
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
  end,
})

local Stopped = Scalar.transition({
  name = 'socket.listener.stopped',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
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
  end,
})

function Listener.new(name, address)
  return setmetatable({
    name = name,
    state = Scalar.machine({
      kind = 'starting',
      address = address,
      handle = nil,
    }, name .. ':lifecycle'),
  }, Listener)
end

function Listener:state_value()
  return self.state.value
end

function Listener:state_op()
  return self.state:read_op()
end

function Listener:activate_op(handle, address)
  return self.state:transition_op(Activate, {
    handle = handle,
    address = address,
  })
end

function Listener:start_failed_op(err, fatal)
  return self.state:transition_op(StartFailed, {
    error = err,
    fatal = fatal == true,
  })
end

function Listener:request_stop_op(reason, err, fatal)
  return self.state:transition_op(RequestStop, {
    reason = reason,
    error = err,
    fatal = fatal == true,
  })
end

function Listener:record_close_error_op(err)
  return self.state:transition_op(RecordCloseError, { error = err })
end

function Listener:stopped_op(reason, err, fatal)
  return self.state:transition_op(Stopped, {
    reason = reason,
    error = err,
    fatal = fatal == true,
  })
end

function Listener:start_result_op()
  return wait_for(self.state, function(state)
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
      HostError.closed('socket', 'listen', {
        reason = state.reason or 'listener closed',
        address = state.address,
      })
    )
  end)
end

function Listener:unavailable_op()
  return wait_for(self.state, function(state)
    if state.kind == 'stopping' or state.kind == 'stopped' then
      return Op.always(state)
    end
    return nil, false
  end)
end

function Listener:terminal_op()
  return wait_for(self.state, function(state)
    if state.kind == 'stopped' then
      return Op.always(state)
    end
    return nil, true
  end)
end

return Listener
