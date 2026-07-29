-- Explicit transactional lifecycle resource for outbound socket dials.

local Op = require('fibers.op')
local StateMachine = require('fibers.resource.machine')
local IOError = require('fibers.io.error')
local Common = require('fibers.socket.lifecycle')

local Ready = StateMachine.Ready
local copy = Common.copy
local wait_for = Common.wait_for

local Dial = {}
Dial.__index = Dial

local Connected = StateMachine.isolated_update('socket.dial.connected', function(current, payload)
  if current.kind ~= 'starting' then
    return Ready.same(false, current)
  end
  local next_state = {
    kind = 'connected',
    address = current.address,
    connection = payload.connection,
    source_scope = payload.source_scope,
    report = payload.report,
  }
  return Ready.write(next_state, true, next_state)
end)

local Failed = StateMachine.isolated_update('socket.dial.failed', function(current, payload)
  if current.kind == 'failed' or current.kind == 'taken' or current.kind == 'closed' then
    return Ready.same(false, current)
  end
  if current.kind == 'closing' then
    local next_state = copy(current)
    if next_state.error == nil then
      next_state.error = payload.error
    end
    if payload.fatal == true then
      next_state.fatal = true
    end
    if payload.report ~= nil and next_state.report == nil then
      next_state.report = payload.report
    end
    return Ready.write(next_state, false, next_state)
  end
  local next_state = {
    kind = 'failed',
    address = current.address,
    error = payload.error,
    fatal = payload.fatal == true,
    connection = current.connection,
    source_scope = current.source_scope,
    report = payload.report or current.report,
  }
  return Ready.write(next_state, true, next_state)
end)

local Take = StateMachine.isolated_update('socket.dial.take', function(current)
  if current.kind ~= 'connected' then
    return StateMachine.Wait
  end
  local next_state = {
    kind = 'taken',
    address = current.address,
    report = current.report,
  }
  return Ready.write(next_state, current.connection, current.source_scope, current.report)
end)

local RequestClose = StateMachine.isolated_update('socket.dial.request_close', function(current, payload)
  if current.kind == 'starting' or current.kind == 'connected' then
    local next_state = {
      kind = 'closing',
      address = current.address,
      reason = payload.reason,
      error = payload.error,
      fatal = payload.fatal == true,
      connection = current.connection,
      source_scope = current.source_scope,
      report = payload.report or current.report,
    }
    return Ready.write(next_state, true, next_state)
  end
  if current.kind == 'closing' then
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
    if payload.report ~= nil and current.report == nil then
      if next_state == current then
        next_state = copy(current)
      end
      next_state.report = payload.report
      needs_write = true
    end
    if needs_write then
      return Ready.write(next_state, false, next_state)
    end
  end
  return Ready.same(false, current)
end)

local Closed = StateMachine.isolated_update('socket.dial.closed', function(current, payload)
  if current.kind == 'closed' or current.kind == 'taken' or current.kind == 'failed' then
    return Ready.same(false, current)
  end
  local next_state = {
    kind = 'closed',
    address = current.address,
    reason = payload.reason or current.reason,
    error = payload.error or current.error,
    fatal = payload.fatal == true or current.fatal == true,
    report = payload.report or current.report,
  }
  return Ready.write(next_state, true, next_state)
end)

function Dial.new(name, address)
  return setmetatable({
    name = name,
    state = StateMachine.new({
      kind = 'starting',
      address = address,
    }, name .. ':lifecycle'),
  }, Dial)
end

function Dial:state_value()
  return self.state.value
end

function Dial:state_op()
  return self.state:read_op()
end

function Dial:publish_connected_op(connection, source_scope, report)
  return self.state:transition_op(Connected, {
    connection = connection,
    source_scope = source_scope,
    report = report,
  })
end

function Dial:publish_failure_op(err, fatal, report)
  return self.state:transition_op(Failed, {
    error = err,
    fatal = fatal == true,
    report = report,
  })
end

function Dial:take_op()
  local lifecycle = self
  return wait_for(self.state, function(state)
    if state.kind == 'starting' then
      return nil, true
    end
    if state.kind == 'connected' then
      return lifecycle.state:transition_op(Take, {})
    end
    return nil, false
  end)
end

function Dial:failure_op()
  return wait_for(self.state, function(state)
    if state.kind == 'starting' then
      return nil, true
    end
    if state.kind == 'connected' then
      return nil, false
    end
    if state.kind == 'failed' then
      return Op.always(state.error)
    end
    if state.kind == 'taken' then
      return Op.always(IOError.closed('socket', 'take_dial_connection', {
        reason = 'connection already taken',
        address = state.address,
      }))
    end
    if state.kind == 'closing' or state.kind == 'closed' then
      return Op.always(state.error or IOError.closed('socket', 'dial', {
        reason = state.reason or 'dial closed',
        address = state.address,
      }))
    end
    return nil, true
  end)
end

function Dial:request_close_op(reason, err, fatal, report)
  return self.state:transition_op(RequestClose, {
    reason = reason,
    error = err,
    fatal = fatal == true,
    report = report,
  })
end

function Dial:closed_op(reason, err, fatal, report)
  return self.state:transition_op(Closed, {
    reason = reason,
    error = err,
    fatal = fatal == true,
    report = report,
  })
end

function Dial:driver_release_op()
  return wait_for(self.state, function(state)
    if state.kind == 'connected' or state.kind == 'starting' then
      return nil, true
    end
    return Op.always(state)
  end)
end

function Dial:report_op()
  return wait_for(self.state, function(state)
    if state.report ~= nil then
      return Op.always(state.report)
    end
    if state.kind == 'starting' or state.kind == 'connected' or state.kind == 'closing' then
      return nil, true
    end
    return nil, false
  end)
end

function Dial:terminal_op()
  return wait_for(self.state, function(state)
    if state.kind == 'failed' or state.kind == 'taken' or state.kind == 'closed' then
      return Op.always(state)
    end
    return nil, true
  end)
end

return Dial
