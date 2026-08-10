-- Explicit transactional lifecycle resource for outbound socket dials.

local StateMachine = require('fibers.resource.machine')
local Label = require('fibers.internal.label')
local IOError = require('fibers.io.error')
local Common = require('fibers.socket.lifecycle')
local TrustedState = require('fibers.internal.trusted_state')

local Ready, Wait = StateMachine.Ready, StateMachine.Wait
local copy = Common.copy
local Dial = {}
Dial.__index = Dial

local function enrich(current, payload)
  local next_state = current
  local function write()
    if next_state == current then next_state = copy(current) end
  end
  if current.error == nil and payload.error ~= nil then
    write()
    next_state.error = payload.error
  end
  if not current.fatal and payload.fatal then
    write()
    next_state.fatal = true
  end
  if current.report == nil and payload.report ~= nil then
    write()
    next_state.report = payload.report
  end
  return next_state
end

local Connected = StateMachine.isolated_update('socket.dial.connected', function(current, payload)
  if current.kind ~= 'starting' then return Ready.same(false, current) end
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
    local next_state = enrich(current, payload)
    if next_state ~= current then return Ready.write(next_state, false, next_state) end
    return Ready.same(false, current)
  end
  local next_state = {
    kind = 'failed',
    address = current.address,
    error = payload.error,
    fatal = payload.fatal,
    connection = current.connection,
    source_scope = current.source_scope,
    report = payload.report or current.report,
  }
  return Ready.write(next_state, true, next_state)
end)

local Take = StateMachine.isolated_select('socket.dial.take', function(current)
  if current.kind ~= 'connected' then return Wait end
  local next_state = { kind = 'taken', address = current.address, report = current.report }
  return Ready.write(next_state, current.connection, current.source_scope, current.report)
end)

local RequestClose = StateMachine.isolated_update('socket.dial.request_close', function(current, payload)
  if current.kind == 'starting' or current.kind == 'connected' then
    local next_state = {
      kind = 'closing',
      address = current.address,
      reason = payload.reason,
      error = payload.error,
      fatal = payload.fatal,
      connection = current.connection,
      source_scope = current.source_scope,
      report = payload.report or current.report,
    }
    return Ready.write(next_state, true, next_state)
  end
  if current.kind == 'closing' then
    local next_state = enrich(current, payload)
    if next_state ~= current then return Ready.write(next_state, false, next_state) end
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
    fatal = payload.fatal or current.fatal or false,
    report = payload.report or current.report,
  }
  return Ready.write(next_state, true, next_state)
end)

local Failure = StateMachine.isolated_query('socket.dial.failure', function(state)
  if state.kind == 'starting' or state.kind == 'connected' then return Wait end
  if state.kind == 'failed' then return Ready.same(state.error) end
  if state.kind == 'taken' then
    return Ready.same(IOError.closed('socket', 'take_dial_connection', {
      reason = 'connection already taken',
      address = state.address,
    }))
  end
  return Ready.same(state.error or IOError.closed('socket', 'dial', {
    reason = state.reason or 'dial closed',
    address = state.address,
  }))
end)

local DriverRelease = StateMachine.isolated_query('socket.dial.driver_release', function(state)
  if state.kind == 'connected' or state.kind == 'starting' then return Wait end
  return Ready.same(state)
end)

local Report = StateMachine.isolated_query('socket.dial.report', function(state)
  if state.report ~= nil then return Ready.same(state.report) end
  return Wait
end)

local Terminal = StateMachine.isolated_query('socket.dial.terminal', function(state)
  if state.kind == 'failed' or state.kind == 'taken' or state.kind == 'closed' then
    return Ready.same(state)
  end
  return Wait
end)

function Dial.new(address)
  local value = Label.attach(setmetatable({
    state = TrustedState.machine({ kind = 'starting', address = address }),
  }, Dial))
  Label.child(value.state, value, 'lifecycle')
  return value
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
  return self.state:transition_op(Take)
end

function Dial:failure_op()
  return self.state:transition_op(Failure)
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
  return self.state:transition_op(DriverRelease)
end

function Dial:report_op()
  return self.state:transition_op(Report)
end

function Dial:terminal_op()
  return self.state:transition_op(Terminal)
end

return Dial
