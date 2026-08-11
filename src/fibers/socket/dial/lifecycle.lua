-- Explicit transactional lifecycle resource for outbound socket dials.

local StateMachine = require('fibers.resource.machine')
local IOError = require('fibers.io.error')
local HostLifecycle = require('fibers.internal.host_lifecycle')

local Ready, Wait = StateMachine.Ready, StateMachine.Wait
local Dial
local ENRICH = { 'error', 'report' }

local function enrich(current, payload)
  local next_state = HostLifecycle.enrich_first(current, payload, ENRICH)
  if payload.fatal and not current.fatal then
    if next_state == current then next_state = HostLifecycle.copy(current) end
    next_state.fatal = true
  end
  return next_state
end

local function update(current, payload)
  local action = payload.action
  if action == 'connected' then
    if current.kind ~= 'starting' then return Ready.same(false, current) end
    local next_state = {
      kind = 'connected', address = current.address, connection = payload.connection,
      source_scope = payload.source_scope, report = payload.report,
    }
    return Ready.write(next_state, true, next_state)
  elseif action == 'failed' then
    if current.kind == 'failed' or current.kind == 'taken' or current.kind == 'closed' then
      return Ready.same(false, current)
    end
    if current.kind == 'closing' then
      local next_state = enrich(current, payload)
      if next_state ~= current then return Ready.write(next_state, false, next_state) end
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'failed', address = current.address, error = payload.error, fatal = payload.fatal,
      connection = current.connection, source_scope = current.source_scope,
      report = payload.report or current.report,
    }
    return Ready.write(next_state, true, next_state)
  elseif action == 'request_close' then
    if current.kind == 'starting' or current.kind == 'connected' then
      local next_state = {
        kind = 'closing', address = current.address, reason = payload.reason,
        error = payload.error, fatal = payload.fatal, connection = current.connection,
        source_scope = current.source_scope, report = payload.report or current.report,
      }
      return Ready.write(next_state, true, next_state)
    end
    if current.kind == 'closing' then
      local next_state = enrich(current, payload)
      if next_state ~= current then return Ready.write(next_state, false, next_state) end
    end
    return Ready.same(false, current)
  elseif action == 'closed' then
    if current.kind == 'closed' or current.kind == 'taken' or current.kind == 'failed' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'closed', address = current.address, reason = payload.reason or current.reason,
      error = payload.error or current.error, fatal = payload.fatal or current.fatal or false,
      report = payload.report or current.report,
    }
    return Ready.write(next_state, true, next_state)
  end
  error('unknown dial lifecycle update: ' .. tostring(action), 0)
end

local function select_state(current)
  if current.kind ~= 'connected' then return Wait end
  local next_state = { kind = 'taken', address = current.address, report = current.report }
  return Ready.write(next_state, current.connection, current.source_scope, current.report)
end

local function query(state, payload)
  local action = payload.action
  if action == 'failure' then
    if state.kind == 'starting' or state.kind == 'connected' then return Wait end
    if state.kind == 'failed' then return Ready.same(state.error) end
    if state.kind == 'taken' then
      return Ready.same(IOError.closed('socket', 'take_dial_connection', {
        reason = 'connection already taken', address = state.address,
      }))
    end
    return Ready.same(state.error or IOError.closed('socket', 'dial', {
      reason = state.reason or 'dial closed', address = state.address,
    }))
  elseif action == 'driver_release' then
    if state.kind == 'connected' or state.kind == 'starting' then return Wait end
    return Ready.same(state)
  elseif action == 'report' then
    if state.report ~= nil then return Ready.same(state.report) end
    return Wait
  elseif action == 'terminal' then
    if state.kind == 'failed' or state.kind == 'taken' or state.kind == 'closed' then return Ready.same(state) end
    return Wait
  end
  error('unknown dial lifecycle query: ' .. tostring(action), 0)
end

Dial = HostLifecycle.define({
  prefix = 'socket.dial',
  initial = function(address) return { kind = 'starting', address = address } end,
  update = update,
  select = select_state,
  query = query,
})

local TAKE = { action = 'take' }
local FAILURE, RELEASE = { action = 'failure' }, { action = 'driver_release' }
local REPORT, TERMINAL = { action = 'report' }, { action = 'terminal' }

function Dial:publish_connected_op(connection, source_scope, report)
  return self:_update_op({ action = 'connected', connection = connection, source_scope = source_scope, report = report })
end
function Dial:publish_failure_op(err, fatal, report)
  return self:_update_op({ action = 'failed', error = err, fatal = fatal == true, report = report })
end
function Dial:take_op() return self:_select_op(TAKE) end
function Dial:failure_op() return self:_query_op(FAILURE) end
function Dial:request_close_op(reason, err, fatal, report)
  return self:_update_op({ action = 'request_close', reason = reason, error = err, fatal = fatal == true, report = report })
end
function Dial:closed_op(reason, err, fatal, report)
  return self:_update_op({ action = 'closed', reason = reason, error = err, fatal = fatal == true, report = report })
end
function Dial:driver_release_op() return self:_query_op(RELEASE) end
function Dial:report_op() return self:_query_op(REPORT) end
function Dial:terminal_op() return self:_query_op(TERMINAL) end

return Dial
