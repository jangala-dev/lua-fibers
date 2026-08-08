-- Scoped message-oriented datagram sockets.
--
-- Datagram boundaries and source addresses are preserved.  Sending admits a
-- complete message to a bounded queue. The driver performs sends after commit;
-- the runtime reactor publishes received packets as bounded host-owned offers.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.net.address')
local IOError = require('fibers.io.error')
local HostHold = require('fibers.io.internal.host_hold')
local IO = require('fibers.io.facility')
local Activation = require('fibers.socket.activation')
local Lifecycle = require('fibers.socket.lifecycle')
local HostOffer = require('fibers.io.offer')
local Closure = require('fibers.closure')
local FIFO = require('fibers.resource.fifo')
local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local Protected = require('fibers.protected')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local DatagramLifecycle = Lifecycle.define({
  prefix = 'socket.datagram',
  error_domain = 'datagram',
  start_action = 'open',
  start_failed_reason = 'datagram start failed',
  closed_reason = 'datagram socket closed',
  available = true,
})

local Ready = StateMachine.Ready
local SendState = {}
SendState.__index = SendState

local Allocate = StateMachine.isolated_update('socket.datagram.allocate_send', function(current)
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
end)

local Complete = StateMachine.isolated_update('socket.datagram.complete_send', function(current, payload)
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
end)

local Fail = StateMachine.isolated_update('socket.datagram.fail_send', function(current, payload)
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
end)

local function wait_flush(state, target)
  return Cell.select_op(state, function(value)
    if value.completed_seq >= target then
      return Op.always(true)
    end
    if value.terminal_error ~= nil and (value.failure_seq or 0) <= target then
      return Op.always(nil, value.terminal_error)
    end
  end)
end

function SendState.new(capacity)
  local self = Label.attach(setmetatable({
    state = StateMachine.new({
      next_seq = 0,
      completed_seq = 0,
      terminal_error = nil,
      failure_seq = nil,
    }),
    queue = FIFO.new(capacity or 64),
  }, SendState))
  Label.child(self.state, self, 'state')
  Label.child(self.queue, self, 'queue')
  return self
end

function SendState:admit_op(data, address)
  return self.state:transition_op(Allocate):and_then(Op.guard(function(seq, err)
    if seq == nil then
      return Op.always(nil, err)
    end
    return self.queue:put_op({ seq = seq, data = data, address = address }):map(function()
      return true, seq
    end)
  end))
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
  return state:read_op():and_then(Op.guard(function(value)
    return wait_flush(state, value.next_seq)
  end))
end

local Module = {}
local Datagram = {}
Datagram.__index = Datagram
local next_datagram = 0

local function close_handle(value, reason)
  return IO.close_value('datagram', value, reason)
end

local function terminal_error(state, action)
  return state.error
    or IOError.closed('datagram', action, {
      reason = state.reason or 'datagram socket closed',
      address = state.address,
    })
end

local function datagram_closure(socket)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return socket:close_op(reason or 'scope closure')
  end, function()
    return socket:closed_op()
  end, {
    name = 'datagram_socket',
    finish_result = Closure.require_ok('datagram closure failed'),
  })
end


local function local_address_now(socket)
  local state = socket._lifecycle.state._location.value
  return state.address or socket._address
end

function Datagram:local_address_op()
  return self._lifecycle.state:select_op(function(state)
    if state.kind == 'starting' then return nil, true end
    return Op.always(state.address or self._address)
  end)
end


local function host_handle(socket)
  local state = socket._lifecycle.state._location.value
  return state and state.handle or nil
end

function Datagram:send_to_op(data, address)
  if type(data) ~= 'string' then
    error('DatagramSocket:send_to_op expects a string payload', 2)
  end
  address = Address.validate(address, 'DatagramSocket:send_to_op')
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    error('DatagramSocket:send_to_op currently supports IPv4 and IPv6 destinations', 2)
  end
  local local_address = local_address_now(self)
  if local_address and local_address.kind ~= address.kind then
    return Op.always(
      nil,
      IOError.invalid_argument('datagram', 'send_to', {
        message = 'datagram source and destination address families differ',
        source = local_address,
        destination = address,
      })
    )
  end
  local send = self._lifecycle:available_op():and_then(
    self._sends:admit_op(data, Address.copy(address)):map(function(ok, seq)
      if not ok then
        return nil, seq
      end
      return true
    end)
  )
  return send:or_else(self._lifecycle:unavailable_op():map(function(state)
    return nil, terminal_error(state, 'send_to')
  end))
end

function Datagram:flush_op()
  return self._sends:flush_op()
end

local RECEIVE_OPTIONS = { max_size = true }

local function limit_packet(packet, opts)
  local max_size = opts.max_size
  if max_size ~= nil then
    if #packet.data > max_size then
      local copy = {}
      for key, value in pairs(packet) do
        copy[key] = value
      end
      copy.original_size = copy.original_size or #packet.data
      copy.data = string.sub(packet.data, 1, max_size)
      copy.truncated = true
      return copy
    end
  end
  return packet
end

function Datagram:receive_from_op(opts)
  opts = Contract.options(opts, RECEIVE_OPTIONS, 'DatagramSocket:receive_from_op options', 2)
  if opts.max_size ~= nil then
    Contract.non_negative_integer(opts.max_size, 'DatagramSocket:receive_from_op max_size', 2)
  end
  local received = self._packets:next_op():map(function(packet)
    return limit_packet(packet, opts)
  end)
  return received:or_else(self._lifecycle:unavailable_op():map(function(state)
    return nil, terminal_error(state, 'receive_from')
  end))
end

function Datagram:close_op(reason)
  local socket = self
  reason = reason or 'datagram socket closed'
  local cancel = socket._driver and socket._driver:request_cancel_op(reason) or Op.always(true)
  return socket._lifecycle
    :request_stop_op(reason)
    :and_then(Op.guard(function(first, state)
      if first and socket._driver then
        return cancel:map(function()
          return first, state
        end)
      end
      return Op.always(first, state)
    end))
    :wrap(function(first, state)
      if first and state.handle then
        local ok, close_err = IO.safe_close('datagram', state.handle, reason, {
          domain = 'datagram',
          action = 'close',
          address = state.address,
        })
        if not ok then
          local rt = Runtime.current()
          if rt then
            IO.masked_perform(rt, socket._lifecycle:record_close_error_op(close_err))
          end
        end
      end
      return true
    end)
end

local function close_result(state)
  if state.close_error then
    return nil, state.close_error
  end
  if state.fatal and state.error then
    return nil, state.error
  end
  return true
end

function Datagram:closed_op()
  return IO.closed_after_driver_op(self._driver, self._lifecycle:terminal_op():map(close_result))
end

local function close_from_driver(socket, rt, reason, err, fatal)
  local first, state = IO.masked_perform(rt, socket._lifecycle:request_stop_op(reason, err, fatal))
  local pending_error = err
    or IOError.closed('datagram', 'send_to', {
      reason = reason,
      address = local_address_now(socket),
    })
  IO.masked_perform(rt, socket._sends:close_op(pending_error))
  if first and state.handle then
    local ok, close_err = IO.safe_close('datagram', state.handle, reason, {
      domain = 'datagram',
      action = 'close',
      address = state.address,
    })
    if not ok then
      IO.masked_perform(rt, socket._lifecycle:record_close_error_op(close_err))
    end
  end
  IO.masked_perform(rt, socket._lifecycle:stopped_op(reason, err, fatal))
end

local function normalise_packet(socket, packet)
  if type(packet) ~= 'table' or type(packet.data) ~= 'string' then
    return nil, IOError.protocol('datagram', 'receive_from', 'host returned an invalid datagram record')
  end
  if packet.peer ~= nil then
    local ok, peer = pcall(Address.validate, packet.peer, 'received datagram peer')
    if not ok then
      return nil, IOError.protocol('datagram', 'receive_from', 'host returned an invalid peer address', {
        cause = peer,
      })
    end
    packet.peer = peer
  end
  packet.local_address = packet.local_address or local_address_now(socket)
  packet.truncated = packet.truncated == true
  packet.flags = packet.flags or {}
  return packet
end

local function packet_source(socket, capacity)
  return HostOffer.new({
    label = Label.describe(socket, socket._fibers_id) .. ':packets',
    domain = 'datagram',
    action = 'receive_from',
    role = 'datagram_packet_source',
    capacity = capacity,
    handle = function() return host_handle(socket) end,
    mode = 'read',
    pull = function(registered_handle)
      local packet, err = registered_handle:recv_from(socket._max_datagram_size)
      if not packet then return nil, err end
      local normalised, packet_err = normalise_packet(socket, packet)
      if not normalised then error(packet_err, 0) end
      return normalised
    end,
    closed_error = function(err)
      return IOError.closed('datagram', 'receive_from', {
        reason = err and err.reason or 'datagram socket closed',
        address = local_address_now(socket),
      })
    end,
  })
end

local function service_send(socket, handle, record)
  local n, err = handle:send_to(record.data, record.address)
  if n ~= nil then
    if n ~= #record.data then
      local protocol = IOError.protocol('datagram', 'send_to', 'host reported a partial datagram send', {
        expected = #record.data,
        actual = n,
        address = record.address,
      })
      perform(socket._sends:fail_op(record.seq, protocol))
      error(protocol, 0)
    end
    perform(socket._sends:complete_op(record.seq))
    return nil
  end
  if IOError.is_would_block(err) then return record end
  err = IOError.normalise(err, {
    domain = 'datagram',
    action = 'send_to',
    address = record.address,
  })
  perform(socket._sends:fail_op(record.seq, err))
  error(err, 0)
end

local function next_driver_event(socket, handle, pending)
  local terminal = socket._packets:terminal_op():map(function(ok, err)
    return 'terminal', ok, err
  end)
  local send = pending and handle:write_ready_op():map(function()
    return 'send', pending
  end) or socket._sends:next_op():map(function(record)
    return 'send', record
  end)
  -- Once packet reception has terminated, do not admit another send turn at the
  -- same boundary. While reception remains live, sending proceeds normally.
  return terminal:or_else(send)
end

local function driver(socket, driver_scope)
  local rt = Runtime.current()
  local ok, driver_err = Protected.pcall(function()
    local handle, start_err = perform(socket._lifecycle:start_result_op())
    if not handle then
      if start_err then IO.masked_perform(rt, socket._sends:close_op(start_err)) end
      return
    end

    perform(socket._packets:open_op(driver_scope))
    local pending
    while true do
      local event, value, err = perform(next_driver_event(socket, handle, pending))
      if event == 'terminal' then
        if not value then error(err, 0) end
        break
      end
      pending = service_send(socket, handle, value)
    end
  end)

  if ok then
    close_from_driver(socket, rt, 'datagram packet source stopped')
    return
  end
  if Runtime.is_cancelled(driver_err) then
    close_from_driver(socket, rt, driver_err.reason or 'datagram cancelled')
    return
  end

  local failure
  local fatal = false
  if IOError.is(driver_err) then
    failure = driver_err
  else
    failure = IO.protocol_error('datagram', 'driver', driver_err, {
      address = local_address_now(socket),
    })
    fatal = true
  end
  close_from_driver(socket, rt, 'datagram driver failed', failure, fatal)
end

local UDP_OPTIONS = {
  scope = true,
  host = true,
  label = true,
  receive_capacity = true,
  send_capacity = true,
  max_datagram_size = true,
  reuse_address = true,
}

function Module.udp_op(address, opts)
  opts = Contract.options(opts, UDP_OPTIONS, 'socket.udp_op options', 2)
  address = Address.validate(address, 'socket.udp_op')
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    error('socket.udp_op currently supports IPv4 and IPv6 local addresses', 2)
  end
  local receive_capacity = opts.receive_capacity or 64
  local send_capacity = opts.send_capacity or 64
  local max_datagram_size = opts._max_datagram_size or 65535
  Contract.positive_integer(receive_capacity, 'socket.udp_op receive_capacity', 2)
  Contract.positive_integer(send_capacity, 'socket.udp_op send_capacity', 2)
  Contract.non_negative_integer(max_datagram_size, 'socket.udp_op max_datagram_size', 2)
  Contract.optional_boolean(opts.reuse_address, 'socket.udp_op reuse_address', 2)
  local scope = IO.current_scope(opts, 'socket.udp_op')
  next_datagram = next_datagram + 1
  local id = 'datagram-' .. tostring(next_datagram)
  local socket = Label.attach(setmetatable({
    kind = 'datagram_socket',
    _fibers_id = id,
    _address = address,
    _lifecycle = DatagramLifecycle.new(address),
    _host_hold = HostHold.new(),
    _sends = SendState.new(send_capacity),
    _max_datagram_size = max_datagram_size,
  }, Datagram), opts.label)
  Label.child(socket._lifecycle, socket, 'lifecycle')
  Label.child(socket._host_hold, socket, 'host-hold')
  Label.child(socket._sends, socket, 'sends')
  socket._packets = packet_source(socket, receive_capacity)

  return IO.admit_driven_lifetime_op(scope, socket, {
    operation = 'socket.udp_op',
    label = Label.get(socket),
    role = 'datagram_socket',
    closure = datagram_closure(socket),
    children = { socket._host_hold },
    run = function(driver_scope) return driver(socket, driver_scope) end,
  }):wrap(function()
    return Activation.create(socket, {
      host = opts.host,
      host_method = 'create_datagram',
      options = { label = opts.label, reuse_address = opts.reuse_address },
      lifecycle = socket._lifecycle,
      hold = socket._host_hold,
      hold_key = 'socket',
      close = close_handle,
      domain = 'datagram',
      action = 'open',
      role = 'datagram',
      address = address,
      closed_reason = 'datagram lifecycle no longer accepts activation',
      closed_message = 'datagram closed before activation',
    })
  end)
end






Module.DatagramSocket = Datagram
Direct.install(Datagram, { 'local_address', 'send_to', 'receive_from', 'flush', 'close', 'closed' })

return Module
