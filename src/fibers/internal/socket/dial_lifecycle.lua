-- Explicit transactional lifecycle resource for outbound socket dials.

local Op = require('fibers.op')
local Scalar = require('fibers.scalar')
local HostError = require('fibers.host.error')
local Common = require('fibers.internal.socket.lifecycle')

local Ready = Scalar.Ready
local copy = Common.copy
local wait_for = Common.wait_for

local Dial = {}
Dial.__index = Dial

local Connected = Scalar.transition({
  name = 'socket.dial.connected',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
    if current.kind ~= 'starting' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'connected',
      address = current.address,
      connection = payload.connection,
      source_region = payload.source_region,
    }
    return Ready.write(next_state, true, next_state)
  end,
})

local Failed = Scalar.transition({
  name = 'socket.dial.failed',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
    if current.kind == 'failed' or current.kind == 'claimed' or current.kind == 'closed' then
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
      return Ready.write(next_state, false, next_state)
    end
    local next_state = {
      kind = 'failed',
      address = current.address,
      error = payload.error,
      fatal = payload.fatal == true,
      connection = current.connection,
      source_region = current.source_region,
    }
    return Ready.write(next_state, true, next_state)
  end,
})

local Claim = Scalar.transition({
  name = 'socket.dial.claim',
  mode = 'update',
  supply = 'none',
  step = function(current)
    if current.kind ~= 'connected' then
      return Scalar.Wait
    end
    local next_state = {
      kind = 'claimed',
      address = current.address,
    }
    return Ready.write(next_state, current.connection, current.source_region)
  end,
})

local RequestClose = Scalar.transition({
  name = 'socket.dial.request_close',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
    if current.kind == 'starting' or current.kind == 'connected' then
      local next_state = {
        kind = 'closing',
        address = current.address,
        reason = payload.reason,
        error = payload.error,
        fatal = payload.fatal == true,
        connection = current.connection,
        source_region = current.source_region,
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
      if needs_write then
        return Ready.write(next_state, false, next_state)
      end
    end
    return Ready.same(false, current)
  end,
})

local Closed = Scalar.transition({
  name = 'socket.dial.closed',
  mode = 'update',
  supply = 'none',
  step = function(current, payload)
    if current.kind == 'closed' or current.kind == 'claimed' or current.kind == 'failed' then
      return Ready.same(false, current)
    end
    local next_state = {
      kind = 'closed',
      address = current.address,
      reason = payload.reason or current.reason,
      error = payload.error or current.error,
      fatal = payload.fatal == true or current.fatal == true,
    }
    return Ready.write(next_state, true, next_state)
  end,
})

function Dial.new(name, address)
  return setmetatable({
    name = name,
    state = Scalar.machine({
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

function Dial:publish_connected_op(connection, source_region)
  return self.state:transition_op(Connected, {
    connection = connection,
    source_region = source_region,
  })
end

function Dial:publish_failure_op(err, fatal)
  return self.state:transition_op(Failed, {
    error = err,
    fatal = fatal == true,
  })
end

function Dial:connected_state_op()
  return wait_for(self.state, function(state)
    if state.kind == 'connected' then
      return Op.always(state)
    end
    if state.kind == 'starting' then
      return nil, true
    end
    return nil, false
  end)
end

function Dial:claim_op()
  local lifecycle = self
  return wait_for(self.state, function(state)
    if state.kind == 'starting' then
      return nil, true
    end
    if state.kind == 'connected' then
      return lifecycle.state:transition_op(Claim, {})
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
    if state.kind == 'claimed' then
      return Op.always(HostError.closed('socket', 'claim_dial_connection', {
        reason = 'connection already claimed',
        address = state.address,
      }))
    end
    if state.kind == 'closing' or state.kind == 'closed' then
      return Op.always(state.error or HostError.closed('socket', 'dial', {
        reason = state.reason or 'dial closed',
        address = state.address,
      }))
    end
    return nil, true
  end)
end

function Dial:request_close_op(reason, err, fatal)
  return self.state:transition_op(RequestClose, {
    reason = reason,
    error = err,
    fatal = fatal == true,
  })
end

function Dial:closed_op(reason, err, fatal)
  return self.state:transition_op(Closed, {
    reason = reason,
    error = err,
    fatal = fatal == true,
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

function Dial:terminal_op()
  return wait_for(self.state, function(state)
    if state.kind == 'failed' or state.kind == 'claimed' or state.kind == 'closed' then
      return Op.always(state)
    end
    return nil, true
  end)
end

return Dial
