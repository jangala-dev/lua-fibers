-- Ordered outbound datagram admission and flush tracking.

local Op = require('fibers.op')
local Scalar = require('fibers.scalar')
local Queue = require('fibers.internal.fifo')
local ScalarWait = require('fibers.internal.scalar_wait')

local Ready = Scalar.Ready
local SendState = {}
SendState.__index = SendState

local Allocate = Scalar.transition({
  name = 'socket.datagram.allocate_send',
  mode = 'update',
  accepts_supply = false,
  supplies = 'none',
  step = function(current)
    if current.terminal_error ~= nil then
      return Ready.same(nil, current.terminal_error)
    end
    local next_state = {
      next_seq = current.next_seq + 1,
      completed_seq = current.completed_seq,
      terminal_error = nil,
      failure_seq = nil,
    }
    return Ready.write(next_state, next_state.next_seq)
  end,
})

local Complete = Scalar.transition({
  name = 'socket.datagram.complete_send',
  mode = 'update',
  accepts_supply = false,
  supplies = 'none',
  step = function(current, payload)
    if payload.seq <= current.completed_seq then
      return Ready.same(true)
    end
    if payload.seq ~= current.completed_seq + 1 then
      return Ready.same(nil, {
        kind = 'datagram_send_order_violation',
        expected = current.completed_seq + 1,
        got = payload.seq,
      })
    end
    local next_state = {
      next_seq = current.next_seq,
      completed_seq = payload.seq,
      terminal_error = current.terminal_error,
      failure_seq = current.failure_seq,
    }
    return Ready.write(next_state, true)
  end,
})

local Fail = Scalar.transition({
  name = 'socket.datagram.fail_send',
  mode = 'update',
  accepts_supply = false,
  supplies = 'none',
  step = function(current, payload)
    if current.terminal_error ~= nil then
      return Ready.same(false, current)
    end
    local next_state = {
      next_seq = current.next_seq,
      completed_seq = current.completed_seq,
      terminal_error = payload.error,
      failure_seq = payload.seq or (current.completed_seq + 1),
    }
    return Ready.write(next_state, true, next_state)
  end,
})

local function wait_flush(state, target)
  return ScalarWait.select_op(state, function(value)
    if value.completed_seq >= target then
      return Op.always(true)
    end
    if value.terminal_error ~= nil and (value.failure_seq or 0) <= target then
      return Op.always(nil, value.terminal_error)
    end
  end)
end

function SendState.new(name, capacity)
  local self = setmetatable({
    name = name,
    state = Scalar.machine({
      next_seq = 0,
      completed_seq = 0,
      terminal_error = nil,
      failure_seq = nil,
    }, name .. ':state'),
    queue = Queue.new({ capacity = capacity or 64, name = name .. ':queue' }),
  }, SendState)
  self._admit_footprint = Op.dependencies(
    self.state:transition_op(Allocate),
    self.queue:put_footprint()
  )
  self._flush_footprint = Op.dependencies(self.state:read_op(), self.state:changed_op(0))
  return self
end

function SendState:admit_footprint()
  return self._admit_footprint
end

function SendState:flush_footprint()
  return self._flush_footprint
end

function SendState:admit_op(data, address)
  return self.state:transition_op(Allocate):and_then(function(seq, err)
    if seq == nil then
      return Op.always(nil, err)
    end
    return self.queue:put_op({ seq = seq, data = data, address = address }):map(function()
      return true, seq
    end)
  end, self._admit_footprint)
end

function SendState:next_op()
  return self.queue:get_op()
end

function SendState:complete_op(seq)
  return self.state:transition_op(Complete, { seq = seq })
end

function SendState:fail_op(seq, err)
  return self.state:transition_op(Fail, { seq = seq, error = err })
end

function SendState:close_op(err)
  return self:fail_op(nil, err)
end

function SendState:flush_op()
  local state = self.state
  return state:read_op():and_then(function(value)
    return wait_flush(state, value.next_seq)
  end, self._flush_footprint)
end

function SendState:state_value()
  return self.state.value
end

return SendState
