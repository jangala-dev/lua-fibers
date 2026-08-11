-- Shared transactional lifecycle machine for listener-like socket resources.

local StateMachine = require('fibers.resource.machine')
local IOError = require('fibers.io.error')
local HostLifecycle = require('fibers.internal.host_lifecycle')

local Ready, Wait = StateMachine.Ready, StateMachine.Wait
local Lifecycle = { copy = HostLifecycle.copy }

function Lifecycle.define(spec)
  local function update(current, payload)
    local action = payload.action
    if action == 'activate' then
      if current.kind ~= 'starting' then return Ready.same(false, current) end
      local next_state = {
        kind = 'active', address = payload.address or current.address, handle = payload.handle,
      }
      return Ready.write(next_state, true, next_state)
    elseif action == 'start_failed' then
      if current.kind ~= 'starting' then return Ready.same(false, current) end
      local next_state = {
        kind = 'stopped', address = current.address, reason = spec.start_failed_reason,
        error = payload.error, fatal = payload.fatal,
      }
      return Ready.write(next_state, true, next_state)
    elseif action == 'request_stop' then
      if current.kind == 'starting' or current.kind == 'active' then
        local next_state = {
          kind = 'stopping', address = current.address, handle = current.handle,
          reason = payload.reason, error = payload.error, fatal = payload.fatal,
        }
        return Ready.write(next_state, true, next_state)
      end
      if current.kind == 'stopping' or current.kind == 'stopped' then
        local next_state = current
        if payload.error ~= nil and current.error == nil then
          next_state = HostLifecycle.copy(current)
          next_state.error = payload.error
        end
        if payload.fatal and not current.fatal then
          if next_state == current then next_state = HostLifecycle.copy(current) end
          next_state.fatal = true
        end
        if next_state ~= current then return Ready.write(next_state, false, next_state) end
      end
      return Ready.same(false, current)
    elseif action == 'record_close_error' then
      if (current.kind ~= 'stopping' and current.kind ~= 'stopped') or current.close_error ~= nil then
        return Ready.same(false, current)
      end
      local next_state = HostLifecycle.copy(current)
      next_state.close_error, next_state.fatal = payload.error, true
      return Ready.write(next_state, true, next_state)
    elseif action == 'stopped' then
      if current.kind == 'stopped' then return Ready.same(false, current) end
      local next_state = HostLifecycle.copy(current)
      next_state.kind = 'stopped'
      next_state.reason = next_state.reason or payload.reason
      if payload.error ~= nil and next_state.error == nil then next_state.error = payload.error end
      if payload.fatal then next_state.fatal = true end
      return Ready.write(next_state, true, next_state)
    end
    error('unknown socket lifecycle update: ' .. tostring(action), 0)
  end

  local function query(state, payload)
    local action = payload.action
    if action == 'start_result' then
      if state.kind == 'starting' then return Wait end
      if state.kind == 'active' then return Ready.same(state.handle) end
      if state.error ~= nil then return Ready.same(nil, state.error) end
      return Ready.same(nil, IOError.closed(spec.error_domain, spec.start_action, {
        reason = state.reason or spec.closed_reason, address = state.address,
      }))
    elseif action == 'address' then
      if state.kind == 'starting' then return Wait end
      return Ready.same(state.address)
    elseif action == 'available' then
      if state.kind == 'starting' or state.kind == 'active' then return Ready.same(true) end
      return Wait
    elseif action == 'unavailable' then
      if state.kind == 'stopping' or state.kind == 'stopped' then return Ready.same(state) end
      return Wait
    elseif action == 'terminal' then
      if state.kind == 'stopped' then return Ready.same(state) end
      return Wait
    end
    error('unknown socket lifecycle query: ' .. tostring(action), 0)
  end

  local Type = HostLifecycle.define({
    prefix = spec.prefix,
    initial = function(address) return { kind = 'starting', address = address } end,
    update = update,
    query = query,
  })
  local START_RESULT, ADDRESS = { action = 'start_result' }, { action = 'address' }
  local AVAILABLE, UNAVAILABLE = { action = 'available' }, { action = 'unavailable' }
  local TERMINAL = { action = 'terminal' }

  function Type:activate_op(handle, address)
    return self:_update_op({ action = 'activate', handle = handle, address = address })
  end
  function Type:start_failed_op(err, fatal)
    return self:_update_op({ action = 'start_failed', error = err, fatal = fatal == true })
  end
  function Type:request_stop_op(reason, err, fatal)
    return self:_update_op({ action = 'request_stop', reason = reason, error = err, fatal = fatal == true })
  end
  function Type:record_close_error_op(err)
    return self:_update_op({ action = 'record_close_error', error = err })
  end
  function Type:stopped_op(reason, err, fatal)
    return self:_update_op({ action = 'stopped', reason = reason, error = err, fatal = fatal == true })
  end
  function Type:start_result_op() return self:_query_op(START_RESULT) end
  function Type:address_op() return self:_query_op(ADDRESS) end
  function Type:available_op() return self:_query_op(AVAILABLE) end
  function Type:unavailable_op() return self:_query_op(UNAVAILABLE) end
  function Type:terminal_op() return self:_query_op(TERMINAL) end
  return Type
end

return Lifecycle
