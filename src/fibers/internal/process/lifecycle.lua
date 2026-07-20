-- Managed process lifecycle state.
--
-- Host work is performed by the Process supervisor after committed options.
-- This resource records public state and the idempotent close request which
-- wakes that supervisor.

local Op = require('fibers.op')
local Scalar = require('fibers.scalar')
local ScalarWait = require('fibers.internal.scalar_wait')

local Lifecycle = {}
Lifecycle.__index = Lifecycle

local Ready = Scalar.Ready

local request_close = Scalar.transition({
  name = 'process.request_close',
  mode = 'update',
  accepts_supply = false,
  supplies = 'none',
  step = function(current, reason)
    if current.requested then
      return Ready.same(true, current.reason)
    end
    return Ready.write({ requested = true, reason = reason or 'process closed' }, true, reason)
  end,
})

local function wait_for(scalar, predicate)
  return ScalarWait.until_op(scalar, predicate)
end

function Lifecycle.new(name)
  return setmetatable({
    name = name,
    state = Scalar.new({ kind = 'created' }, name .. ':state'),
    close_request = Scalar.machine({ requested = false, reason = nil }, name .. ':close-request'),
  }, Lifecycle)
end

function Lifecycle:state_op()
  return self.state:read_op()
end

function Lifecycle:state_value()
  return self.state.value
end

function Lifecycle:set_state_op(value)
  return self.state:write_op(value)
end

function Lifecycle:request_close_op(reason)
  return self.close_request:transition_op(request_close, reason)
end

function Lifecycle:close_requested_op()
  return wait_for(self.close_request, function(value)
    if value.requested then
      return true, value.reason
    end
    return false
  end)
end

function Lifecycle:is_close_requested()
  return self.close_request.value.requested == true
end

function Lifecycle:close_reason()
  return self.close_request.value.reason
end

return Lifecycle
