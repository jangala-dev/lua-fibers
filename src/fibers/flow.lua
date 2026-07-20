-- Transactional byte flow.
--
-- A Flow has one stable producer Inlet and one stable consumer Outlet.  It
-- provides bounded buffering, exact and delimiter-based reads, closure,
-- producer-side capacity reservations, and consumer-side byte leases.  Every
-- public `_op` method constructs an option; no bytes move until that option is
-- selected by perform.
--
-- The implementation uses one Scalar state machine. Endpoint state, terminal
-- errors, retained bytes, and the active data and space leases share that
-- state, so ordinary Flow options compile to one primitive transition.

local Op = require('fibers.op')
local Scalar = require('fibers.scalar')
local Machine = require('fibers.internal.flow_machine')
local Lease = require('fibers.flow.lease')
local SpaceLease = require('fibers.flow.space_lease')
local Errors = require('fibers.flow.errors')
local Ownership = require('fibers.internal.ownership')
local Settlement = require('fibers.internal.settlement')

local Flow = {}
Flow.__index = Flow

local Inlet = {}
Inlet.__index = Inlet
local Outlet = {}
Outlet.__index = Outlet
local Reservoir = {}
Reservoir.__index = Reservoir

local next_id = 0
local function validate_options(opts, allowed, label)
  for key in pairs(opts or {}) do
    if not allowed[key] then
      error((label or 'options') .. ' does not accept ' .. tostring(key), 3)
    end
  end
end

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then
    error('flow bytes must be a string', 3)
  end
  return bytes
end
local function as_nonneg_int(n, default, label)
  if n == nil then
    n = default
  end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'flow byte count') .. ' must be a non-negative integer', 3)
  end
  return n
end
local function as_pos_int(n, default, label)
  n = as_nonneg_int(n, default, label)
  if n <= 0 then
    error((label or 'flow byte count') .. ' must be positive', 3)
  end
  return n
end
local function as_capacity(n)
  if n == nil then
    return nil
  end
  return as_nonneg_int(n, nil, 'flow capacity')
end

local new_state = Machine.new_state
local inspect_state = Machine.inspect
local free_for_capacity = Machine.free
local transition_op = Machine.transition_op

function Reservoir.new(flow, opts)
  opts = opts or {}
  local r = setmetatable(
    { flow = flow, capacity = as_capacity(opts.capacity), limit = as_capacity(opts.capacity) },
    Reservoir
  )
  return r
end
function Reservoir:_op(name, payload)
  return transition_op(self.flow, name, payload)
end
function Reservoir:inspect_op()
  return self.flow:inspect_op()
end
function Reservoir:read_some_op(n)
  n = as_pos_int(n, 1, 'flow read size')
  return self:_op('read_some', { n = n })
end
function Reservoir:peek_op(n)
  n = as_nonneg_int(n, 1, 'flow peek size')
  if n == 0 then
    return Op.always('')
  end
  return self:_op('peek', { n = n })
end
function Reservoir:read_exactly_op(n)
  n = as_nonneg_int(n, 0, 'flow exact read size')
  if n == 0 then
    return Op.always('')
  end
  return self:_op('read_exactly', { n = n })
end
function Reservoir:read_until_op(sep, opts)
  opts = opts or {}
  if type(sep) ~= 'string' or sep == '' then
    error('flow read_until separator must be non-empty string', 2)
  end
  local limit = opts.limit
  if limit ~= nil then
    limit = as_nonneg_int(limit, nil, 'flow read limit')
  end
  return self:_op('read_until', { sep = sep, limit = limit, include = opts.include == true, err = opts.err })
end
function Reservoir:drain_available_op()
  return self:_op('drain_available')
end
function Reservoir:read_all_limited_op(opts)
  opts = opts or {}
  return self:_op('drain_all_limited', { max = opts.max, unlimited = opts.unlimited == true })
end
function Reservoir:read_all_too_large_op(opts)
  opts = opts or {}
  return self:_op('read_all_too_large', { max = opts.max, unlimited = opts.unlimited == true })
end
function Reservoir:capacity_some_op(n)
  n = as_pos_int(n, 1, 'flow capacity count')
  return self:_op('capacity_some', { n = n })
end
function Reservoir:lease_op(n, owner, meta)
  n = as_pos_int(n, 1, 'flow lease size')
  return self:_op('lease', { n = n, owner = owner, meta = meta })
end
function Reservoir:ack_lease_op(lease, n)
  if not Lease.is(lease) then
    error('ack_lease_op expects a flow lease', 2)
  end
  n = as_nonneg_int(n, lease:length(), 'flow lease ack count')
  return self:_op('ack_lease', { lease = lease, n = n })
end
function Reservoir:return_lease_op(lease)
  if not Lease.is(lease) then
    error('return_lease_op expects a flow lease', 2)
  end
  return self:_op('return_lease', { lease = lease })
end
function Reservoir:fail_lease_op(lease, err)
  if not Lease.is(lease) then
    error('fail_lease_op expects a flow lease', 2)
  end
  return self:_op('fail_lease', { lease = lease, err = err })
end
function Reservoir:reserve_space_op(n, owner, meta)
  n = as_pos_int(n, 1, 'flow space reservation size')
  return self:_op('reserve_space', { n = n, owner = owner, meta = meta })
end
function Reservoir:commit_space_op(lease, bytes)
  if not SpaceLease.is(lease) then
    error('commit_space_op expects a flow space lease', 2)
  end
  bytes = as_bytes(bytes)
  return self:_op('commit_space', { lease = lease, bytes = bytes })
end
function Reservoir:release_space_op(lease)
  if not SpaceLease.is(lease) then
    error('release_space_op expects a flow space lease', 2)
  end
  return self:_op('release_space', { lease = lease })
end
function Reservoir:fail_space_op(lease, err)
  if not SpaceLease.is(lease) then
    error('fail_space_op expects a flow space lease', 2)
  end
  return self:_op('fail_space', { lease = lease, err = err })
end
function Reservoir:settle_op(err)
  return self:_op('settle', { err = err })
end
function Reservoir:settled_error_op()
  return self:_op('settled_error')
end
function Reservoir:empty_op()
  return self:_op('empty')
end

local function live_or_retired_op(handle, body)
  local flow = handle and handle.flow or handle
  if (handle and handle._fibers_retired) or (flow and flow._fibers_retired) then
    return Op.always(nil, Errors.RETIRED)
  end
  return body()
end

function Inlet:write_op(bytes)
  bytes = as_bytes(bytes)
  if bytes == '' then
    return Op.always(0)
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'write', { bytes = bytes })
  end)
end

function Inlet:write_some_op(bytes)
  bytes = as_bytes(bytes)
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'write_some', { bytes = bytes })
  end)
end

function Inlet:reserve_some_op(n, owner, meta)
  return live_or_retired_op(self, function()
    return self.flow.reservoir:reserve_space_op(n, owner, meta)
  end)
end

function Inlet:flush_op()
  return transition_op(self.flow, 'flush')
end

function Inlet:close_op(_reason)
  return transition_op(self.flow, 'close_input')
end

function Inlet:closed_op()
  return transition_op(self.flow, 'input_closed')
end

function Inlet:fail_op(reason)
  return transition_op(self.flow, 'set_input_error', { err = reason or Errors.READ_ERROR })
end

function Outlet:read_some_op(n)
  n = as_nonneg_int(n, 1, 'flow read size')
  if n == 0 then
    return Op.always('')
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_some', { n = n })
  end)
end

function Outlet:read_exactly_op(n)
  n = as_nonneg_int(n, 0, 'flow exact read size')
  if n == 0 then
    return Op.always('')
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_exactly', { n = n })
  end)
end

function Outlet:peek_exactly_op(n)
  return live_or_retired_op(self, function()
    return self.flow.reservoir:peek_op(n)
  end)
end

function Outlet:read_until_op(separator, opts)
  opts = opts or {}
  validate_options(opts, { include = true, max = true }, 'read_until_op options')
  if type(separator) ~= 'string' or separator == '' then
    error('flow read_until separator must be a non-empty string', 2)
  end
  local max = opts.max
  if max == nil then
    max = 8192
  end
  max = as_nonneg_int(max, nil, 'flow read_until max')
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_until_or_eof', {
      sep = separator,
      limit = max,
      include = opts.include == true,
      err = Errors.TOO_LARGE,
    })
  end)
end

function Outlet:read_line_op(opts)
  opts = opts or {}
  validate_options(opts, { terminator = true, keep_terminator = true, max = true }, 'read_line_op options')
  local terminator = opts.terminator or '\n'
  if type(terminator) ~= 'string' or terminator == '' then
    error('flow line terminator must be a non-empty string', 2)
  end
  local max = opts.max
  if max == nil then
    max = 8192
  end
  max = as_nonneg_int(max, nil, 'flow line max')
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_until_or_eof', {
      sep = terminator,
      limit = max,
      include = opts.keep_terminator == true,
      err = Errors.LINE_TOO_LONG,
      line_mode = true,
    })
  end)
end

function Outlet:read_all_op(opts)
  opts = opts or {}
  validate_options(opts, { max = true }, 'read_all_op options')
  if opts.max == nil then
    error('read_all_op expects opts.max', 2)
  end
  local max = as_nonneg_int(opts.max, nil, 'flow read_all max')
  local read_opts = { max = max, unlimited = false }
  return live_or_retired_op(self, function()
    return self.flow.reservoir
      :read_all_too_large_op(read_opts)
      :and_then(function(err)
        return Op.always(nil, err)
      end)
      :or_else(transition_op(self.flow, 'input_closed'):and_then(function()
        return self.flow.reservoir:read_all_limited_op(read_opts)
      end))
  end)
end

function Outlet:drop_op(n)
  n = as_nonneg_int(n, 0, 'flow drop size')
  if n == 0 then
    return Op.always(0)
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'drop_exactly', { n = n })
  end)
end

function Outlet:splice_to_op(inlet, n)
  n = as_nonneg_int(n, 0, 'flow splice size')
  return self:peek_exactly_op(n):and_then(function(bytes)
    return inlet:write_op(bytes):and_then(function(written, err)
      if not written then
        if err == Errors.CAPACITY then
          err = Errors.TOO_LARGE
        end
        return Op.always(nil, err)
      end
      return self:drop_op(n)
    end)
  end)
end

function Outlet:lease_some_op(n, owner, meta)
  return live_or_retired_op(self, function()
    return self.flow.reservoir:lease_op(n, owner, meta)
  end)
end

function Outlet:close_op(reason)
  return transition_op(self.flow, 'shutdown_output', { err = reason or Errors.CLOSED })
end

function Outlet:closed_op()
  return transition_op(self.flow, 'output_closed')
end

function Outlet:fail_op(err)
  return transition_op(self.flow, 'fail_write', { err = err or Errors.WRITE_ERROR })
end

function Flow.new(opts)
  opts = opts or {}
  validate_options(opts, { name = true, capacity = true }, 'Flow.new options')
  next_id = next_id + 1
  local name = opts.name or ('flow-' .. tostring(next_id))
  local self = Ownership.handle(name, { kind = 'flow' })
  setmetatable(self, Flow)
  self.name = name
  self.capacity = as_capacity(opts.capacity)
  self.limit = self.capacity
  self.state = Scalar.machine(new_state(), name .. ':state')
  self.reservoir = Reservoir.new(self, opts)
  self.reservoir.state = self.state
  self._fibers_settle = Settlement.flow()
  self._fibers_settle_name = 'flow'
  self.input = Ownership.handle(name .. ':inlet', { kind = 'flow_inlet', flow = self })
  setmetatable(self.input, Inlet)
  self.output = Ownership.handle(name .. ':outlet', { kind = 'flow_outlet', flow = self })
  setmetatable(self.output, Outlet)
  return self
end

function Flow:_read_serviceable()
  local state = self.state.value
  if not state or state.input_error or state.output_error then
    return false
  end
  if state.input_open == false or state.output_open == false or state.space_id then
    return false
  end
  return free_for_capacity(self.capacity, state) > 0
end

function Flow:_write_serviceable()
  local state = self.state.value
  if not state or state.output_error or state.output_open == false then
    return false
  end
  if state.lease_id then
    return true
  end
  return not state.rope:is_empty()
end

function Flow:_read_terminal_reason()
  local state = self.state.value
  if not state then
    return nil
  end
  if state.output_open == false then
    return 'reader_closed'
  end
  if state.input_error then
    return state.input_error
  end
  if state.output_error then
    return state.output_error
  end
  if state.input_open == false then
    return Errors.EOF
  end
  return nil
end

function Flow:_write_terminal_reason(draining)
  local state = self.state.value
  if not state then
    return nil
  end
  if state.output_error then
    return state.output_error
  end
  if state.output_open == false then
    return Errors.BROKEN_PIPE
  end
  if state.input_error then
    return state.input_error
  end
  if state.input_open == false and not state.lease_id and state.rope:is_empty() then
    return draining and Errors.CLOSED_AND_DRAINED or Errors.CLOSED
  end
  return nil
end

function Flow:inlet()
  return self.input
end

function Flow:outlet()
  return self.output
end

function Flow:inspect_op()
  return self.state:read_op():map(function(s)
    return inspect_state(self, s)
  end)
end

function Flow:abort_op(_reason)
  return transition_op(self, 'shutdown_flow')
end

function Flow:closed_op()
  return transition_op(self, 'closed')
end

Flow.Error = {
  EOF = Errors.EOF,
  CLOSED = Errors.CLOSED,
  BROKEN_PIPE = Errors.BROKEN_PIPE,
  TOO_LARGE = Errors.TOO_LARGE,
  LINE_TOO_LONG = Errors.LINE_TOO_LONG,
  RETIRED = Errors.RETIRED,
}

return Flow
