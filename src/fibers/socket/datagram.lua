-- Scoped message-oriented datagram sockets.
--
-- Datagram boundaries and source addresses are preserved.  Sending admits a
-- complete message to a bounded queue; the owned driver performs sendto/recvfrom
-- only after the construction option has committed.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.socket.address')
local HostError = require('fibers.host.error')
local Adoption = require('fibers.internal.adoption')
local IO = require('fibers.internal.io')
local Lifecycle = require('fibers.internal.socket.datagram_lifecycle')
local SendState = require('fibers.internal.socket.datagram_send_state')
local DatagramService = require('fibers.internal.socket.datagram_service')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.internal.settlement')
local Queue = require('fibers.internal.fifo')
local Protected = require('fibers.internal.protected')
local perform = require('fibers.perform')

local Module = {}
local Datagram = {}
Datagram.__index = Datagram
local next_datagram = 0

local function close_handle(value, reason)
  return IO.close_value('datagram', value, reason)
end

local function terminal_error(state, action)
  return state.error
    or HostError.closed('datagram', action, {
      reason = state.reason or 'datagram socket closed',
      address = state.address,
    })
end

local function datagram_settlement(socket)
  return Settlement.request_then_wait(function(_ctx, _record, reason)
    return socket:close_op(reason or 'scope settlement')
  end, function()
    return socket:closed_op():and_then(function(ok, err)
      if not ok then
        error(err or 'datagram settlement failed', 0)
      end
      return Op.always(true)
    end)
  end)
end

function Datagram:owned(children)
  return Owned.tree(self, self._fibers_settle, children or {}, {
    role = 'datagram_socket',
    settle_name = 'datagram_socket',
  })
end

function Datagram:state_op()
  return self.lifecycle:state_op()
end

function Datagram:state_value()
  return self.lifecycle:state_value()
end

function Datagram:local_address()
  local state = self.lifecycle:state_value()
  return state.address or self.address
end

function Datagram:host_handle()
  return self.lifecycle:state_value().handle
end

function Datagram:send_to_op(data, address)
  if type(data) ~= 'string' then
    error('DatagramSocket:send_to_op expects a string payload', 2)
  end
  address = Address.validate(address, 'DatagramSocket:send_to_op')
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    error('DatagramSocket:send_to_op currently supports IPv4 and IPv6 destinations', 2)
  end
  local local_address = self:local_address()
  if local_address and local_address.kind ~= address.kind then
    return Op.always(
      nil,
      HostError.invalid_argument('datagram', 'send_to', {
        message = 'datagram source and destination address families differ',
        source = local_address,
        destination = address,
      })
    )
  end
  local send = self.lifecycle:available_op():and_then(function()
    return self.sends:admit_op(data, Address.copy(address)):map(function(ok, seq)
      if not ok then
        return nil, seq
      end
      return true
    end)
  end, self.sends:admit_footprint())
  return send:or_else(self.lifecycle:unavailable_op():map(function(state)
    return nil, terminal_error(state, 'send_to')
  end))
end

function Datagram:flush_op()
  return self.sends:flush_op()
end

local function limit_packet(packet, opts)
  opts = opts or {}
  local max_size = opts.max_size and tonumber(opts.max_size) or nil
  if max_size ~= nil then
    if max_size < 0 or max_size ~= math.floor(max_size) then
      error('DatagramSocket:receive_from_op max_size must be a non-negative integer', 3)
    end
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
  opts = IO.copy_table(opts)
  local received = self.incoming:get_op():map(function(packet)
    return limit_packet(packet, opts)
  end)
  return received:or_else(self.lifecycle:unavailable_op():map(function(state)
    return nil, terminal_error(state, 'receive_from')
  end))
end

function Datagram:close_op(reason)
  local socket = self
  reason = reason or 'datagram socket closed'
  local cancel = socket.driver and socket.driver:request_cancel_op(reason) or Op.always(true)
  return socket.lifecycle
    :request_stop_op(reason)
    :and_then(function(first, state)
      if first and socket.driver then
        return cancel:map(function()
          return first, state
        end)
      end
      return Op.always(first, state)
    end, cancel)
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
            IO.masked_perform(rt, socket.lifecycle:record_close_error_op(close_err))
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
  local joined = self.driver and self.driver:exit_op() or Op.always(true)
  local lifecycle = self.lifecycle
  local terminal = lifecycle:terminal_op()
  return joined:and_then(function()
    return terminal:map(close_result)
  end, terminal)
end

local function close_from_driver(socket, rt, reason, err, fatal)
  local first, state = IO.masked_perform(rt, socket.lifecycle:request_stop_op(reason, err, fatal))
  local pending_error = err
    or HostError.closed('datagram', 'send_to', {
      reason = reason,
      address = socket:local_address(),
    })
  IO.masked_perform(rt, socket.sends:close_op(pending_error))
  if first and state.handle then
    local ok, close_err = IO.safe_close('datagram', state.handle, reason, {
      domain = 'datagram',
      action = 'close',
      address = state.address,
    })
    if not ok then
      IO.masked_perform(rt, socket.lifecycle:record_close_error_op(close_err))
    end
  end
  IO.masked_perform(rt, socket.lifecycle:stopped_op(reason, err, fatal))
end

local function normalise_packet(socket, packet)
  if type(packet) ~= 'table' or type(packet.data) ~= 'string' then
    return nil, HostError.protocol('datagram', 'receive_from', 'host returned an invalid datagram record')
  end
  if packet.peer ~= nil then
    local ok, peer = pcall(Address.validate, packet.peer, 'received datagram peer')
    if not ok then
      return nil,
        HostError.protocol('datagram', 'receive_from', 'host returned an invalid peer address', {
          cause = peer,
        })
    end
    packet.peer = peer
  end
  packet.local_address = packet.local_address or socket:local_address()
  packet.truncated = packet.truncated == true
  packet.flags = packet.flags or {}
  return packet
end

local function service_receive(socket, handle)
  local packet, err = handle:recv_from(socket.max_datagram_size)
  if packet then
    local normalised, packet_err = normalise_packet(socket, packet)
    if not normalised then
      error(packet_err, 0)
    end
    perform(socket.incoming:put_op(normalised))
    return true, true
  end
  if HostError.is_would_block(err) then
    return true, false
  end
  if HostError.is(err, 'closed') then
    return false, false
  end
  error(
    HostError.normalise(err, {
      domain = 'datagram',
      action = 'receive_from',
      address = socket:local_address(),
    }),
    0
  )
end

local function service_send(socket, handle, record)
  local n, err = handle:send_to(record.data, record.address)
  if n ~= nil then
    if n ~= #record.data then
      local protocol = HostError.protocol('datagram', 'send_to', 'host reported a partial datagram send', {
        expected = #record.data,
        actual = n,
        address = record.address,
      })
      perform(socket.sends:fail_op(record.seq, protocol))
      error(protocol, 0)
    end
    perform(socket.sends:complete_op(record.seq))
    return nil, true
  end
  if HostError.is_would_block(err) then
    return record, false
  end
  err = HostError.normalise(err, {
    domain = 'datagram',
    action = 'send_to',
    address = record.address,
  })
  perform(socket.sends:fail_op(record.seq, err))
  error(err, 0)
end

local function driver(socket)
  local rt = Runtime.current()
  local ok, driver_err = Protected.pcall(function()
    local handle, start_err = perform(socket.lifecycle:start_result_op())
    if not handle then
      if start_err then
        IO.masked_perform(rt, socket.sends:close_op(start_err))
      end
      return
    end

    local pending
    local service = DatagramService.new(socket.service_quantum)
    while true do
      local event
      event, pending = perform(service:next_op(handle, socket.sends, pending))

      local progressed
      if event.kind == 'read' then
        local continue
        continue, progressed = service_receive(socket, handle)
        if not continue then
          break
        end
      else
        pending, progressed = service_send(socket, handle, event.record or pending)
      end

      if progressed then
        service:progress(event.kind)
      end
    end
  end)

  if ok then
    close_from_driver(socket, rt, 'datagram driver stopped')
    return
  end
  if Runtime.is_cancelled(driver_err) then
    close_from_driver(socket, rt, driver_err.reason or 'datagram cancelled')
    return
  end

  local failure
  local fatal = false
  if HostError.is(driver_err) then
    failure = driver_err
  else
    failure = IO.protocol_error('datagram', 'driver', driver_err, {
      address = socket:local_address(),
    })
    fatal = true
  end
  close_from_driver(socket, rt, 'datagram driver failed', failure, fatal)
end

function Module.datagram_op(address, opts)
  opts = IO.copy_table(opts)
  address = Address.validate(address, 'socket.datagram_op')
  if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
    error('socket.datagram_op currently supports IPv4 and IPv6 local addresses', 2)
  end
  local receive_capacity = tonumber(opts.receive_capacity or 64)
  local send_capacity = tonumber(opts.send_capacity or 64)
  local max_datagram_size = tonumber(opts.max_datagram_size or 65535)
  if not receive_capacity or receive_capacity < 1 or receive_capacity ~= math.floor(receive_capacity) then
    error('socket.datagram_op receive_capacity must be a positive integer', 2)
  end
  if not send_capacity or send_capacity < 1 or send_capacity ~= math.floor(send_capacity) then
    error('socket.datagram_op send_capacity must be a positive integer', 2)
  end
  if not max_datagram_size or max_datagram_size < 0 or max_datagram_size ~= math.floor(max_datagram_size) then
    error('socket.datagram_op max_datagram_size must be a non-negative integer', 2)
  end
  local service_quantum = tonumber(opts.service_quantum or 1)
  if not service_quantum or service_quantum < 1 or service_quantum ~= math.floor(service_quantum) then
    error('socket.datagram_op service_quantum must be a positive integer', 2)
  end
  local owner = IO.current_owner(opts, 'socket.datagram_op')
  next_datagram = next_datagram + 1
  local name = opts.name or ('datagram-' .. tostring(next_datagram))
  local socket = Ownership.handle(name, {
    kind = 'datagram_socket',
    address = address,
    scope_owner = owner,
    lifecycle = Lifecycle.new(name, address),
    adoption = Adoption.slot(name .. ':adoption'),
    incoming = Queue.new({ capacity = receive_capacity, name = name .. ':incoming' }),
    sends = SendState.new(name .. ':sends', send_capacity),
    max_datagram_size = max_datagram_size,
    service_quantum = service_quantum,
    driver = nil,
  })
  setmetatable(socket, Datagram)
  socket._fibers_settle = datagram_settlement(socket)

  local driver_parent = IO.scope_for_owner(owner, 'socket.datagram_op')
  socket.driver = IO.new_driver_task(driver_parent, name .. ':driver', function()
    return driver(socket)
  end)

  local owned = socket:owned({
    socket.adoption:owned({ role = 'datagram_adoption' }),
    socket.driver:owned(),
  })

  return owner
    :admit_op(owned)
    :and_then(function()
      return socket.driver:spawn_effect_op()
    end, false)
    :wrap(function()
      local rt = Runtime.current()
      local host = opts.host or (rt and rt.host)
      if not host or type(host.create_datagram) ~= 'function' then
        local err = HostError.unsupported('host', 'datagram', { address = address })
        IO.masked_perform(rt, socket.lifecycle:start_failed_op(err))
        return nil, err
      end

      local called, handle, err = Protected.pcall(function()
        return host:create_datagram(address, opts)
      end)
      if not called then
        local failure = IO.protocol_error('datagram', 'open', handle, { address = address })
        IO.masked_perform(rt, socket.lifecycle:start_failed_op(failure, true))
        error(failure, 0)
      end
      if not handle then
        err = HostError.normalise(err, { domain = 'datagram', action = 'open', address = address })
        IO.masked_perform(rt, socket.lifecycle:start_failed_op(err))
        return nil, err
      end

      local adopted, adoption_err = socket.adoption:adopt(handle, close_handle)
      if not adopted then
        IO.masked_perform(rt, socket.lifecycle:start_failed_op(adoption_err, true))
        return nil, adoption_err
      end
      if type(handle.bind_runtime) == 'function' then
        handle:bind_runtime(rt)
      end
      local local_address = type(handle.local_address) == 'function' and handle:local_address() or address
      local released, release_err = socket.adoption:release(handle)
      if not released then
        close_handle(handle, release_err)
        IO.masked_perform(rt, socket.lifecycle:start_failed_op(release_err, true))
        return nil, release_err
      end
      local activated = IO.masked_perform(rt, socket.lifecycle:activate_op(handle, local_address or address))
      if not activated then
        close_handle(handle, 'datagram lifecycle no longer accepts activation')
        return nil,
          HostError.closed('datagram', 'open', {
            reason = 'datagram closed before activation',
            address = address,
          })
      end
      return socket
    end)
end

function Datagram:send_to(data, address)
  return perform(self:send_to_op(data, address))
end

function Datagram:receive_from(opts)
  return perform(self:receive_from_op(opts))
end

function Datagram:flush()
  return perform(self:flush_op())
end

function Datagram:close(reason)
  return perform(self:close_op(reason))
end

function Datagram:closed()
  return perform(self:closed_op())
end

Module.DatagramSocket = Datagram
return Module
