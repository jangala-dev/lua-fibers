-- Scoped message-oriented datagram sockets.
--
-- Datagram boundaries and source addresses are preserved.  Sending admits a
-- complete message to a bounded queue. The driver performs sends after commit;
-- the runtime reactor publishes received packets as bounded host-owned offers.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.net.address')
local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
local Activation = require('fibers.socket.activation')
local Lifecycle = require('fibers.socket.lifecycle')
local HostOffer = require('fibers.io.offer')
local FIFO = require('fibers.resource.fifo')
local Counter = require('fibers.resource.counter')
local Completion = require('fibers.resource.completion')
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
})

local function admit_send_op(socket, data, address)
  return socket._send_failed:pending_op():and_then(socket._send_admitted:bump_op()):and_then(Op.guard(function(seq)
    return socket._send_queue:put_op({ seq = seq, data = data, address = address }):map(function() return true, seq end)
  end))
end

local function complete_send_op(socket, seq)
  return socket._send_completed:read_op():and_then(Op.guard(function(done)
    if seq <= done then return Op.always(true) end
    if seq ~= done + 1 then
      return Op.always(nil, { kind = 'datagram_send_order_violation', expected = done + 1, got = seq })
    end
    return socket._send_completed:bump_op():map(function() return true end)
  end))
end

local function fail_send_op(socket, seq, err)
  return socket._send_failed:publish_success_op({ seq = seq, error = err })
end

local function flush_send_op(socket)
  return socket._send_admitted:read_op():and_then(Op.guard(function(target)
    local complete = socket._send_completed:at_least_op(target):map(function() return true end)
    local failed = socket._send_failed:success_op():and_then(Op.guard(function(failure)
      if failure.seq == nil or failure.seq <= target then return Op.always(nil, failure.error) end
      return Op.never()
    end))
    return complete:or_else(failed)
  end))
end

local Module = {}
local Datagram = {}
Datagram.__index = Datagram

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

local function close_socket_handle(socket, rt, state, reason)
  if socket._handle_closed or not state.handle then return end
  socket._handle_closed = true
  local ok, close_err = IO.safe_close('datagram', state.handle, reason, {
    domain = 'datagram',
    action = 'close',
    address = state.address,
  })
  if not ok then IO.masked_perform(rt, socket._lifecycle:record_close_error_op(close_err)) end
end

function Datagram:local_address_op()
  return self._lifecycle:address_op()
end

function Datagram:ready_op()
  return self._lifecycle:start_result_op():map(function(handle, err)
    if not handle then return nil, err end
    return self
  end)
end

function Datagram:send_to_op(data, address)
  if type(data) ~= 'string' then
    error('DatagramSocket:send_to_op expects a string payload', 2)
  end
  address = Address.validate(address, 'DatagramSocket:send_to_op')
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    error('DatagramSocket:send_to_op currently supports IPv4 and IPv6 destinations', 2)
  end
  local local_address = Lifecycle.address(self)
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
    admit_send_op(self, data, Address.copy(address)):map(function(ok, seq)
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
  return flush_send_op(self)
end

local RECEIVE_OPTIONS = { max_size = Contract.non_negative_integer }

local function limit_packet(packet, opts)
  local max_size = opts.max_size
  if max_size == nil or #packet.data <= max_size then return packet end
  local copy = {}
  for key, value in pairs(packet) do copy[key] = value end
  copy.original_size = copy.original_size or #packet.data
  copy.data = string.sub(packet.data, 1, max_size)
  copy.truncated = true
  return copy
end

function Datagram:receive_from_op(opts)
  opts = Contract.options(opts, RECEIVE_OPTIONS, 'DatagramSocket:receive_from_op options', 2)
  local received = self._packets:next_op():map(function(packet)
    return limit_packet(packet, opts)
  end)
  return received:or_else(self._lifecycle:unavailable_op():map(function(state)
    return nil, terminal_error(state, 'receive_from')
  end))
end

function Datagram:request_close_op(reason)
  reason = reason or 'datagram socket closed'
  return self._lifecycle
    :request_stop_op(reason)
    :and_then(Op.guard(function(first, state)
      if first and self._driver then
        return self._driver:request_cancel_op(reason):map(function() return first, state end)
      end
      return Op.always(first, state)
    end))
    :map(function(first, state) return true, first, state end)
end

function Datagram:closed_op()
  return IO.closed_after_driver_op(self._driver)
end

function Datagram:close(reason)
  local requested, request_err = perform(self:request_close_op(reason))
  if not requested then return nil, request_err end
  return perform(self:closed_op())
end

local function close_from_driver(socket, rt, reason, err, fatal)
  local _, state = IO.masked_perform(rt, socket._lifecycle:request_stop_op(reason, err, fatal))
  local pending_error = err
    or IOError.closed('datagram', 'send_to', {
      reason = reason,
      address = Lifecycle.address(socket),
    })
  IO.masked_perform(rt, fail_send_op(socket, nil, pending_error))
  close_socket_handle(socket, rt, state, reason)
  local _, terminal = IO.masked_perform(rt, socket._lifecycle:stopped_op(reason, err, fatal))
  return Lifecycle.close_result(terminal)
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
  packet.local_address = packet.local_address or Lifecycle.address(socket)
  packet.flags = packet.flags or {}
  packet.truncated = packet.truncated == true or packet.flags.truncated == true
  packet.original_size = packet.original_size or packet.flags.original_size
  return packet
end

local function packet_source(socket, capacity)
  return HostOffer.new({
    label = Label.describe(socket, socket._fibers_id) .. ':packets',
    domain = 'datagram',
    action = 'receive_from',
    role = 'datagram_packet_source',
    capacity = capacity,
    handle = function() return Lifecycle.handle(socket) end,
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
        address = Lifecycle.address(socket),
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
      perform(fail_send_op(socket, record.seq, protocol))
      error(protocol, 0)
    end
    perform(complete_send_op(socket, record.seq))
    return nil
  end
  if IOError.is_would_block(err) then return record end
  err = IOError.normalise(err, {
    domain = 'datagram',
    action = 'send_to',
    address = record.address,
  })
  perform(fail_send_op(socket, record.seq, err))
  error(err, 0)
end

local function next_driver_event(socket, handle, pending)
  local terminal = socket._packets:terminal_op():map(function(ok, err)
    return 'terminal', ok, err
  end)
  local send = pending and handle:write_ready_op():map(function()
    return 'send', pending
  end) or socket._send_queue:get_op():map(function(record)
    return 'send', record
  end)
  -- Once packet reception has terminated, do not admit another send turn at the
  -- same boundary. While reception remains live, sending proceeds normally.
  return terminal:or_else(send)
end

local function driver(socket, driver_scope, opts, address)
  local rt = Runtime.current()
  local activated, active, activation_err = Protected.pcall(Activation.create, socket, {
    host = opts.host,
    host_method = 'create_datagram',
    options = { label = opts.label, reuse_address = opts.reuse_address },
    lifecycle = socket._lifecycle,
    close = close_handle,
    domain = 'datagram',
    action = 'open',
    role = 'datagram',
    address = address,
    closed_reason = 'datagram lifecycle no longer accepts activation',
    closed_message = 'datagram closed before activation',
  })
  if not activated then
    local failure = IOError.is(active) and active or IO.protocol_error('datagram', 'open', active, { address = address })
    IO.masked_perform(rt, fail_send_op(socket, nil, failure))
    return nil, failure
  end
  if not active then
    if activation_err then IO.masked_perform(rt, fail_send_op(socket, nil, activation_err)) end
    return nil, activation_err
  end

  local handle = Lifecycle.handle(socket)
  local ok, driver_err = Protected.pcall(function()
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
    return close_from_driver(socket, rt, 'datagram packet source stopped')
  end
  if Runtime.is_cancelled(driver_err) then
    return close_from_driver(socket, rt, driver_err.reason or 'datagram cancelled')
  end

  local failure
  local fatal = false
  if IOError.is(driver_err) then
    failure = driver_err
  else
    failure = IO.protocol_error('datagram', 'driver', driver_err, {
      address = Lifecycle.address(socket),
    })
    fatal = true
  end
  return close_from_driver(socket, rt, 'datagram driver failed', failure, fatal)
end

local UDP_OPTIONS = {
  scope = true,
  host = true,
  label = Contract.non_empty_string,
  receive_capacity = Contract.positive_integer,
  send_capacity = Contract.positive_integer,
  max_datagram_size = Contract.non_negative_integer,
  reuse_address = Contract.boolean,
}

function Module.submit_udp_op(address, opts)
  opts = Contract.options(opts, UDP_OPTIONS, 'socket.submit_udp_op options', 2)
  address = Address.validate(address, 'socket.submit_udp_op')
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    error('socket.submit_udp_op currently supports IPv4 and IPv6 local addresses', 2)
  end
  local receive_capacity = opts.receive_capacity or 64
  local send_capacity = opts.send_capacity or 64
  local max_datagram_size = opts.max_datagram_size or 65535
  local scope = IO.current_scope(opts, 'socket.submit_udp_op')
  local socket = Label.attach(Label.identity(setmetatable({
    kind = 'datagram_socket',
    _address = address,
    _lifecycle = DatagramLifecycle.new(address),
    _send_admitted = Counter.new(0), _send_completed = Counter.new(0),
    _send_failed = Completion.new(), _send_queue = FIFO.new(send_capacity),
    _max_datagram_size = max_datagram_size,
  }, Datagram), 'datagram'), opts.label)
  Label.child(socket._lifecycle, socket, 'lifecycle')
  for _, name in ipairs({ 'admitted', 'completed', 'failed', 'queue' }) do
    Label.child(socket['_send_' .. name], socket, 'sends:' .. name)
  end
  socket._packets = packet_source(socket, receive_capacity)

  return scope:_drive_op(socket, {
    label = Label.get(socket),
    role = 'datagram_socket',
    closure = IO._closeable_closure(socket, {
      name = 'datagram_socket', reason = 'scope closure', request = 'request_close_op',
      finish_result = 'datagram closure failed',
    }),
    run = function(driver_scope) return driver(socket, driver_scope, opts, address) end,
  })
end

function Module.udp(address, opts)
  local socket, err = perform(Module.submit_udp_op(address, opts))
  if not socket then return nil, err end
  local ready, ready_err = socket:ready()
  if not ready then
    socket:closed()
    return nil, ready_err
  end
  return socket
end





Module.DatagramSocket = Datagram
Direct.install(Datagram, {
  'ready', 'local_address', 'send_to', 'receive_from', 'flush', 'request_close', 'closed',
})

return Module
