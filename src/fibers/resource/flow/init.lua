-- Transactional byte flow.
--
-- Buffering, byte leases, space reservations, capacity and endpoint state form
-- one serial law. Streams and host adapters build on the inlet and outlet.

local Closure = require('fibers.closure')
local Effect = require('fibers.effect')
local Facility = require('fibers.resource.authoring')
local Lifetime = require('fibers.lifetime')
local Machine = require('fibers.resource.machine')
local Op = require('fibers.op')
local Errors = require('fibers.resource.flow.errors')
local Rope = require('fibers.resource.flow.rope')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local Ready, Wait = Machine.Ready, Machine.Wait
local INF = math.huge

local Flow, Inlet, Outlet = {}, {}, {}
local Lease, SpaceLease = {}, {}
Flow.__index, Inlet.__index, Outlet.__index = Flow, Inlet, Outlet
Lease.__index, SpaceLease.__index = Lease, SpaceLease

local Kind = Facility.kind('flow')

-- Values --------------------------------------------------------------------

local function bytes(value, level)
  if type(value) ~= 'string' then error('flow bytes must be a string', level or 3) end
  return value
end

local function count(value, default, label, positive)
  value = value == nil and default or value
  if type(value) ~= 'number' or value ~= value or value < 0 or value ~= math.floor(value) then
    error((label or 'flow byte count') .. ' must be a non-negative integer', 3)
  end
  if positive and value == 0 then error((label or 'flow byte count') .. ' must be positive', 3) end
  return value
end

local function capacity(value)
  return value == nil and INF or count(value, nil, 'flow capacity')
end

local function options(opts, allowed, label)
  return Contract.options(opts, allowed, label, 3)
end

local function separator(value, label)
  if type(value) ~= 'string' or value == '' then
    error((label or 'flow separator') .. ' must be a non-empty string', 3)
  end
  return value
end

-- Leases --------------------------------------------------------------------

local function lease(flow, record)
  return setmetatable({
    flow = flow,
    id = record.id,
    holder = record.holder,
    meta = record.meta,
    _bytes = record.bytes,
  }, Lease)
end

function Lease:bytes() return self._bytes end
function Lease:length() return #self._bytes end
function Lease:ack_op(n) return self.flow:_ack_lease_op(self, n) end


function Lease:release_op() return self.flow:_return_lease_op(self) end


function Lease:fail_op(err) return self.flow:_fail_lease_op(self, err) end


local function space_lease(flow, record)
  return setmetatable({
    flow = flow,
    id = record.id,
    holder = record.holder,
    meta = record.meta,
    _capacity = record.capacity,
  }, SpaceLease)
end

function SpaceLease:capacity() return self._capacity end
function SpaceLease:commit_op(value) return self.flow:_commit_space_op(self, value) end


function SpaceLease:release_op() return self.flow:_release_space_op(self) end


function SpaceLease:fail_op(err) return self.flow:_fail_space_op(self, err) end


-- State ---------------------------------------------------------------------

local function new_state()
  return {
    input_open = true,
    output_open = true,
    input_error = nil,
    output_error = nil,
    rope = Rope.new(),
    lease = nil,
    next_lease = 0,
    space = nil,
    next_space = 0,
    settled_error = nil,
  }
end

local function copy_state(state, clone_rope)
  local out = {}
  for key, value in pairs(state) do out[key] = value end
  if clone_rope then out.rope = state.rope:clone() end
  return out
end

local function retained(state)
  local leased = state.lease and #state.lease.bytes or 0
  local reserved = state.space and state.space.capacity or 0
  return state.rope:length() + leased + reserved
end

local function free(flow, state)
  return flow.capacity == INF and INF or flow.capacity - retained(state)
end

local function committed_closed(flow, endpoint)
  local state = flow and flow._state and flow._state.value
  return state and state[endpoint .. '_open'] == false
end

local function close_endpoint(state, endpoint)
  state[endpoint .. '_open'] = false
end

local function fail_endpoint(state, endpoint, err)
  state[endpoint .. '_error'] = err
  close_endpoint(state, endpoint)
end

local function clear_retained(state)
  state.rope = Rope.new()
  state.lease = nil
  state.space = nil
end

local function write_error(state)
  if state.output_error then return state.output_error end
  if not state.input_open then return Errors.CLOSED end
  if not state.output_open then return Errors.BROKEN_PIPE end
end

local function find_until(state, sep)
  local pos = state.rope:find(sep)
  return pos and pos + #sep or nil, pos
end

-- Host notification ---------------------------------------------------------

local Changed
Changed = Effect.kind({
  name = 'flow_changed',
  key = function(payload) return payload.flow._fibers_id end,
  merge = function(first) return first end,
  validate_payload = function(_, payload)
    if type(payload.flow) ~= 'table' or payload.flow._fibers_id == nil then
      return nil, { kind = 'invalid_effect_payload', message = 'flow_changed effect requires a Flow' }
    end
    return true
  end,
  prepare = function(_, payload)
    return {
      kind = Changed,
      key = payload.flow._fibers_id,
      payload = payload,
      discharge = function(runtime, prepared)
        local reactor = runtime.host_reactor
        if reactor and reactor._notify_flow_changed then
          reactor:_notify_flow_changed(prepared.payload.flow)
        end
        return true
      end,
    }
  end,
})

local function transition(flow, rule, payload)
  payload = payload or {}
  payload.flow = flow
  local option = flow._state:transition_op(rule, payload)
  if rule.mode == 'query' then return option end
  return option:and_then(Op.guard(function(...)
    local result = Facility.pack(...)
    return Op.emit(Effect.of(Changed, { flow = flow })):map(function()
      return Facility.unpack(result, 1, result.n)
    end)
  end))
end

-- Rules ---------------------------------------------------------------------

local function update(name, step, order, validate)
  return Machine.update('flow.' .. name, step, order, validate)
end

local function select_when(name, ready, step, order)
  return Machine.select_when('flow.' .. name, ready, step, order)
end

local function query(name, step, order)
  return Machine.query('flow.' .. name, step, order)
end

local T = {}

T.write = select_when('write', function(state, payload)
  local value = payload.bytes
  return write_error(state) ~= nil
    or #value > payload.flow.capacity
    or #value <= free(payload.flow, state)
end, function(state, payload)
  local err = write_error(state)
  if err then return Ready.same(nil, err) end
  local value = payload.bytes
  if #value > payload.flow.capacity then return Ready.same(nil, Errors.CAPACITY) end
  if #value > free(payload.flow, state) then return Wait end
  local next = copy_state(state, true)
  next.rope:append(value)
  return Ready.write(next, #value)
end, 100)

T.write_some = update('write_some', function(state, payload)
  local value, err = payload.bytes, write_error(state)
  if err then return Ready.same(nil, value, err) end
  local room = free(payload.flow, state)
  if room <= 0 or value == '' then return Ready.same(0, value) end
  local n = math.min(#value, room)
  local next = copy_state(state, true)
  next.rope:append(value:sub(1, n))
  return Ready.write(next, n, value:sub(n + 1))
end, 100)

T.read_some = select_when('read_some', function(state, payload)
  return state.input_error ~= nil or state.rope:length() > 0 or committed_closed(payload.flow, 'input')
end, function(state, payload)
  if state.input_error then return Ready.same(nil, state.input_error) end
  local available = state.rope:length()
  if available > 0 then
    local next = copy_state(state, true)
    return Ready.write(next, next.rope:take(math.min(payload.n, available)))
  end
  if committed_closed(payload.flow, 'input') then return Ready.same(nil, Errors.EOF) end
  return Wait
end, 50)

T.read_exactly = select_when('read_exactly', function(state, payload)
  return state.input_error ~= nil
    or state.rope:length() >= payload.n
    or committed_closed(payload.flow, 'input')
end, function(state, payload)
  if state.input_error then return Ready.same(nil, state.input_error) end
  local available = state.rope:length()
  if available >= payload.n then
    local next = copy_state(state, true)
    return Ready.write(next, next.rope:take(payload.n))
  end
  if not committed_closed(payload.flow, 'input') then return Wait end
  if available == 0 then return Ready.same(nil, Errors.EOF, '') end
  local next = copy_state(state, true)
  return Ready.write(next, nil, Errors.EOF, next.rope:take(available))
end, 50)

T.read_until = select_when('read_until', function(state, payload)
  if state.input_error then return true end
  local finish = find_until(state, payload.sep)
  if finish then return true end
  if state.rope:length() > payload.limit and not state.rope:ends_with_prefix(payload.sep) then return true end
  return committed_closed(payload.flow, 'input')
end, function(state, payload)
  if state.input_error then return Ready.same(nil, state.input_error) end
  local finish, data_len = find_until(state, payload.sep)
  if finish then
    if data_len > payload.limit then return Ready.same(nil, payload.err) end
    local next = copy_state(state, true)
    local out = next.rope:take(finish)
    return Ready.write(next, payload.include and out or out:sub(1, #out - #payload.sep))
  end
  local available = state.rope:length()
  if available > payload.limit and not state.rope:ends_with_prefix(payload.sep) then
    return Ready.same(nil, payload.err)
  end
  if not committed_closed(payload.flow, 'input') then return Wait end
  if available == 0 then return Ready.same(nil, Errors.EOF) end
  local next = copy_state(state, true)
  local partial = next.rope:take(available)
  if payload.line then return Ready.write(next, partial) end
  return Ready.write(next, nil, Errors.EOF, partial)
end, 50)

T.read_all = select_when('read_all', function(state, payload)
  return state.rope:length() > payload.max or committed_closed(payload.flow, 'input')
end, function(state, payload)
  local available = state.rope:length()
  if available > payload.max then return Ready.same(nil, Errors.TOO_LARGE) end
  if not committed_closed(payload.flow, 'input') then return Wait end
  if available == 0 then return Ready.same('') end
  local next = copy_state(state, true)
  return Ready.write(next, next.rope:take(available))
end, 50)

T.peek = query('peek', function(state, payload)
  if state.rope:length() < payload.n then return Wait end
  return Ready.same(state.rope:peek(payload.n))
end, 100)

T.drop = select_when('drop', function(state, payload)
  return state.input_error ~= nil
    or state.rope:length() >= payload.n
    or committed_closed(payload.flow, 'input')
end, function(state, payload)
  if state.input_error then return Ready.same(nil, state.input_error) end
  local available = state.rope:length()
  if available >= payload.n then
    local next = copy_state(state, true)
    next.rope:take(payload.n)
    return Ready.write(next, payload.n)
  end
  if not committed_closed(payload.flow, 'input') then return Wait end
  if available == 0 then return Ready.same(nil, Errors.EOF, 0) end
  local next = copy_state(state, true)
  next.rope:take(available)
  return Ready.write(next, nil, Errors.EOF, available)
end, 50)

T.lease = select_when('lease', function(state, payload)
  return state.lease ~= nil or not state.rope:is_empty() or committed_closed(payload.flow, 'input')
end, function(state, payload)
  if state.lease then
    if payload.holder ~= nil and state.lease.holder == payload.holder then
      return Ready.same(lease(payload.flow, state.lease))
    end
    return Ready.same(nil, Errors.LEASE_ALREADY_ACTIVE)
  end
  if state.rope:is_empty() then
    if committed_closed(payload.flow, 'input') then return Ready.same(nil, Errors.CLOSED_AND_DRAINED) end
    return Wait
  end
  local next = copy_state(state, true)
  next.next_lease = state.next_lease + 1
  next.lease = {
    id = next.next_lease,
    holder = payload.holder,
    meta = payload.meta,
    bytes = next.rope:take(math.min(payload.n, next.rope:length())),
  }
  return Ready.write(next, lease(payload.flow, next.lease))
end, 50)

T.ack_lease = update('ack_lease', function(state, payload)
  local current = state.lease
  if not current or current.id ~= payload.lease.id then return Ready.same(false, Errors.NO_LEASE) end
  if payload.n > #current.bytes then return Ready.same(false, Errors.LEASE_ACK_TOO_LARGE) end
  if payload.n == 0 then return Ready.same(true, 0) end
  local next = copy_state(state)
  local remaining = current.bytes:sub(payload.n + 1)
  if remaining == '' then
    next.lease = nil
  else
    next.lease = { id = current.id, holder = current.holder, meta = current.meta, bytes = remaining }
  end
  return Ready.write(next, true, payload.n)
end)

T.return_lease = update('return_lease', function(state, payload)
  local current = state.lease
  if not current or current.id ~= payload.lease.id then return Ready.same(false, Errors.NO_LEASE) end
  local next = copy_state(state, current.bytes ~= '')
  if current.bytes ~= '' then next.rope:prepend(current.bytes) end
  next.lease = nil
  return Ready.write(next, true, #current.bytes)
end)

T.fail_lease = update('fail_lease', function(state, payload)
  local current = state.lease
  if not current or current.id ~= payload.lease.id then return Ready.same(false, Errors.NO_LEASE) end
  local next = copy_state(state)
  next.lease = nil
  next.settled_error = payload.err or Errors.FLOW_ERROR
  return Ready.write(next, true, #current.bytes)
end)

T.reserve = select_when('reserve', function(state, payload)
  return write_error(state) ~= nil or state.space ~= nil or free(payload.flow, state) > 0
end, function(state, payload)
  local err = write_error(state)
  if err then return Ready.same(nil, err) end
  if state.space then
    if payload.holder ~= nil and state.space.holder == payload.holder then
      return Ready.same(space_lease(payload.flow, state.space))
    end
    return Ready.same(nil, Errors.SPACE_LEASE_ALREADY_ACTIVE)
  end
  local room = free(payload.flow, state)
  if room <= 0 then return Wait end
  local next = copy_state(state)
  next.next_space = state.next_space + 1
  next.space = {
    id = next.next_space,
    holder = payload.holder,
    meta = payload.meta,
    capacity = math.min(payload.n, room),
  }
  return Ready.write(next, space_lease(payload.flow, next.space))
end, 90)

T.commit_space = update('commit_space', function(state, payload)
  local current = state.space
  if not current or current.id ~= payload.lease.id then return Ready.same(nil, Errors.NO_SPACE_LEASE) end
  if #payload.bytes > current.capacity then return Ready.same(nil, Errors.SPACE_COMMIT_TOO_LARGE) end
  local next = copy_state(state, payload.bytes ~= '')
  next.space = nil
  if payload.bytes ~= '' then next.rope:append(payload.bytes) end
  return Ready.write(next, #payload.bytes)
end)

T.release_space = update('release_space', function(state, payload)
  local current = state.space
  if not current or current.id ~= payload.lease.id then return Ready.same(false, Errors.NO_SPACE_LEASE) end
  local next = copy_state(state)
  next.space = nil
  return Ready.write(next, true, current.capacity)
end)

T.fail_space = update('fail_space', function(state, payload)
  local current = state.space
  if not current or current.id ~= payload.lease.id then return Ready.same(false, Errors.NO_SPACE_LEASE) end
  local next = copy_state(state)
  next.space = nil
  fail_endpoint(next, 'input', payload.err or Errors.READ_ERROR)
  return Ready.write(next, true)
end)

T.flush = query('flush', function(state)
  if state.settled_error then return Ready.same(nil, state.settled_error) end
  if retained(state) == 0 then return Ready.same(true) end
  return Wait
end, 100)

T.close_input = update('close_input', function(state)
  if not state.input_open then return Ready.same(true) end
  local next = copy_state(state)
  close_endpoint(next, 'input')
  return Ready.write(next, true)
end)

T.input_closed = query('input_closed', function(_, payload)
  if committed_closed(payload.flow, 'input') then return Ready.same(true) end
  return Wait
end, 100)

T.fail_input = update('fail_input', function(state, payload)
  local next = copy_state(state)
  fail_endpoint(next, 'input', payload.err or Errors.READ_ERROR)
  return Ready.write(next, true)
end)

T.shutdown_output = update('shutdown_output', function(state, payload)
  local next = copy_state(state)
  fail_endpoint(next, 'output', state.output_error or Errors.BROKEN_PIPE)
  local pending = retained(state)
  clear_retained(next)
  if pending > 0 then next.settled_error = payload.err end
  return Ready.write(next, true)
end)

T.output_closed = query('output_closed', function(_, payload)
  if committed_closed(payload.flow, 'output') then return Ready.same(true) end
  return Wait
end, 100)

T.fail_write = update('fail_write', function(state, payload)
  local next = copy_state(state)
  fail_endpoint(next, 'output', payload.err)
  local pending = retained(state)
  clear_retained(next)
  if pending > 0 then next.settled_error = payload.err end
  return Ready.write(next, false, payload.err)
end)

T.shutdown = update('shutdown', function(state)
  if not state.input_open and not state.output_open and retained(state) == 0 then return Ready.same(true) end
  local next = copy_state(state)
  close_endpoint(next, 'input')
  close_endpoint(next, 'output')
  clear_retained(next)
  return Ready.write(next, true)
end)

T.closed = query('closed', function(state)
  if state.input_open or state.output_open or retained(state) ~= 0 then return Wait end
  if state.settled_error then return Ready.same(nil, state.settled_error) end
  return Ready.same(true)
end, 100)

-- Endpoint lifetime ---------------------------------------------------------

local function define_endpoint(endpoint, role, right)
  Lifetime.define(endpoint, {
    role = role,
    rights = { [right] = true, use = true },
    closure = Closure.request_then_wait(
      function(_, record) return record.item:close_op() end,
      function(_, record) return record.item:closed_op() end,
      { name = role, finish_result = Closure.require_ok(role .. ' closure failed') }
    ),
  })
end

local function live(handle, body)
  local lifetime = Lifetime.of(handle)
  local phase = lifetime and lifetime:current_state().closure_phase
  if phase == 'closed' or phase == 'closure_failed' then return Op.always(nil, Errors.RETIRED) end
  return body()
end

-- Inlet ---------------------------------------------------------------------

function Inlet:write_op(value)
  value = bytes(value, 2)
  if value == '' then return Op.always(0) end
  return live(self, function() return transition(self.flow, T.write, { bytes = value }) end)
end


function Inlet:write_some_op(value)
  value = bytes(value, 2)
  return live(self, function() return transition(self.flow, T.write_some, { bytes = value }) end)
end


function Inlet:reserve_some_op(n, holder, meta)
  n = count(n, 1, 'flow space reservation size', true)
  return live(self, function()
    return transition(self.flow, T.reserve, { n = n, holder = holder, meta = meta })
  end)
end


function Inlet:flush_op() return transition(self.flow, T.flush) end


function Inlet:close_op() return transition(self.flow, T.close_input) end


function Inlet:closed_op() return transition(self.flow, T.input_closed) end


function Inlet:fail_op(err)
  return transition(self.flow, T.fail_input, { err = err or Errors.READ_ERROR })
end


-- Outlet --------------------------------------------------------------------

function Outlet:read_some_op(n)
  n = count(n, 1, 'flow read size')
  if n == 0 then return Op.always('') end
  return live(self, function() return transition(self.flow, T.read_some, { n = n }) end)
end


function Outlet:read_exactly_op(n)
  n = count(n, 0, 'flow exact read size')
  if n == 0 then return Op.always('') end
  return live(self, function() return transition(self.flow, T.read_exactly, { n = n }) end)
end


function Outlet:peek_exactly_op(n)
  n = count(n, 1, 'flow peek size')
  if n == 0 then return Op.always('') end
  return live(self, function() return transition(self.flow, T.peek, { n = n }) end)
end


function Outlet:read_until_op(sep, opts)
  opts = options(opts, { include = true, max = true }, 'read_until_op options')
  Contract.optional_boolean(opts.include, 'read_until_op opts.include', 2)
  sep = separator(sep, 'flow read_until separator')
  return live(self, function()
    return transition(self.flow, T.read_until, {
      sep = sep,
      limit = count(opts.max, 8192, 'flow read_until max'),
      include = opts.include == true,
      err = Errors.TOO_LARGE,
    })
  end)
end


function Outlet:read_line_op(opts)
  opts = options(opts, { terminator = true, keep_terminator = true, max = true }, 'read_line_op options')
  Contract.optional_boolean(opts.keep_terminator, 'read_line_op opts.keep_terminator', 2)
  if opts.terminator ~= nil then separator(opts.terminator, 'flow line terminator') end
  return live(self, function()
    return transition(self.flow, T.read_until, {
      sep = separator(opts.terminator or '\n', 'flow line terminator'),
      limit = count(opts.max, 8192, 'flow line max'),
      include = opts.keep_terminator == true,
      err = Errors.LINE_TOO_LONG,
      line = true,
    })
  end)
end


function Outlet:read_all_op(opts)
  opts = options(opts, { max = true }, 'read_all_op options')
  if opts.max == nil then error('read_all_op expects opts.max', 2) end
  return live(self, function()
    return transition(self.flow, T.read_all, { max = count(opts.max, nil, 'flow read_all max') })
  end)
end


function Outlet:drop_op(n)
  n = count(n, 0, 'flow drop size')
  if n == 0 then return Op.always(0) end
  return live(self, function() return transition(self.flow, T.drop, { n = n }) end)
end


function Outlet:splice_to_op(inlet, n)
  n = count(n, 0, 'flow splice size')
  return self:peek_exactly_op(n):and_then(Op.guard(function(value)
    return inlet:write_op(value):and_then(Op.guard(function(written, err)
      if not written then
        return Op.always(nil, err == Errors.CAPACITY and Errors.TOO_LARGE or err)
      end
      return self:drop_op(n)
    end))
  end))
end


function Outlet:lease_some_op(n, holder, meta)
  n = count(n, 1, 'flow lease size', true)
  return live(self, function()
    return transition(self.flow, T.lease, { n = n, holder = holder, meta = meta })
  end)
end


function Outlet:close_op(reason)
  return transition(self.flow, T.shutdown_output, { err = reason or Errors.CLOSED })
end


function Outlet:closed_op() return transition(self.flow, T.output_closed) end


function Outlet:fail_op(err)
  err = err or Errors.WRITE_ERROR
  return transition(self.flow, T.fail_write, { err = err })
end


-- Lease operations ----------------------------------------------------------

local function require_lease(flow, value, kind, label)
  if getmetatable(value) ~= kind or value.flow ~= flow then
    error(label .. ' expects a lease from this flow', 3)
  end
end

function Flow:_ack_lease_op(value, n)
  require_lease(self, value, Lease, 'ack_lease_op')
  return transition(self, T.ack_lease, {
    lease = value,
    n = count(n, value:length(), 'flow lease ack count'),
  })
end

function Flow:_return_lease_op(value)
  require_lease(self, value, Lease, 'return_lease_op')
  return transition(self, T.return_lease, { lease = value })
end

function Flow:_fail_lease_op(value, err)
  require_lease(self, value, Lease, 'fail_lease_op')
  return transition(self, T.fail_lease, { lease = value, err = err })
end

function Flow:_commit_space_op(value, data)
  require_lease(self, value, SpaceLease, 'commit_space_op')
  return transition(self, T.commit_space, { lease = value, bytes = bytes(data, 2) })
end

function Flow:_release_space_op(value)
  require_lease(self, value, SpaceLease, 'release_space_op')
  return transition(self, T.release_space, { lease = value })
end

function Flow:_fail_space_op(value, err)
  require_lease(self, value, SpaceLease, 'fail_space_op')
  return transition(self, T.fail_space, { lease = value, err = err })
end

-- Flow ----------------------------------------------------------------------

function Flow.new(limit)
  local flow = Facility.identity(setmetatable({ capacity = capacity(limit) }, Flow), Kind)
  flow._state = Machine.new(new_state())
  Label.child(flow._state, flow, 'state')
  flow._inlet = Label.attach(setmetatable({
    _fibers_id = flow._fibers_id .. ':inlet',
    flow = flow,
  }, Inlet))
  flow._outlet = Label.attach(setmetatable({
    _fibers_id = flow._fibers_id .. ':outlet',
    flow = flow,
  }, Outlet))
  define_endpoint(flow._inlet, 'flow_inlet', 'write')
  define_endpoint(flow._outlet, 'flow_outlet', 'read')
  Label.child(flow._inlet, flow, 'inlet')
  Label.child(flow._outlet, flow, 'outlet')
  Label.child(Lifetime.of(flow._inlet), flow, 'inlet')
  Label.child(Lifetime.of(flow._outlet), flow, 'outlet')
  return flow
end

function Flow:inlet() return self._inlet end
function Flow:outlet() return self._outlet end
function Flow:abort_op() return transition(self, T.shutdown) end


function Flow:closed_op() return transition(self, T.closed) end


-- Host reactor contract -----------------------------------------------------

function Flow:_read_serviceable()
  local state = self._state.value
  return state
    and not state.input_error
    and not state.output_error
    and state.input_open
    and state.output_open
    and not state.space
    and free(self, state) > 0
    or false
end

function Flow:_write_serviceable()
  local state = self._state.value
  return state
    and not state.output_error
    and state.output_open
    and (state.lease ~= nil or not state.rope:is_empty())
    or false
end

function Flow:_read_terminal_reason()
  local state = self._state.value
  if not state then return nil end
  if not state.output_open then return 'reader_closed' end
  if state.input_error then return state.input_error end
  if state.output_error then return state.output_error end
  if not state.input_open then return Errors.EOF end
end

function Flow:_write_terminal_reason(draining)
  local state = self._state.value
  if not state then return nil end
  if state.output_error then return state.output_error end
  if not state.output_open then return Errors.BROKEN_PIPE end
  if state.input_error then return state.input_error end
  if not state.input_open and not state.lease and state.rope:is_empty() then
    return draining and Errors.CLOSED_AND_DRAINED or Errors.CLOSED
  end
end

Flow.Error = {
  EOF = Errors.EOF,
  CLOSED = Errors.CLOSED,
  BROKEN_PIPE = Errors.BROKEN_PIPE,
  TOO_LARGE = Errors.TOO_LARGE,
  LINE_TOO_LONG = Errors.LINE_TOO_LONG,
  RETIRED = Errors.RETIRED,
}

Direct.install(Lease, { 'ack', 'release', 'fail' })
Direct.install(SpaceLease, { 'commit', 'release', 'fail' })
Direct.install(Inlet, { 'write', 'write_some', 'reserve_some', 'flush', 'close', 'closed', 'fail' })
Direct.install(Outlet, { 'read_some', 'read_exactly', 'peek_exactly', 'read_until', 'read_line', 'read_all', 'drop', 'splice_to', 'lease_some', 'close', 'closed', 'fail' })
Direct.install(Flow, { 'abort', 'closed' })

return Flow
