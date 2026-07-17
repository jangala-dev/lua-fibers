-- Scoped stream sockets.
--
-- Listening and dial admission are options.  Connected sockets are ordinary
-- Streams.  Host acquisition occurs only after the corresponding option
-- commits; accepted and dialled handles are covered by adoption slots until
-- Stream ownership is established.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Stream = require('fibers.stream')
local HandleBackend = require('fibers.stream.backend.handle')
local HostError = require('fibers.host.error')
local Adoption = require('fibers.internal.adoption')
local Completion = require('fibers.internal.completion')
local Ownership = require('fibers.internal.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.internal.settlement')
local Queue = require('fibers.internal.fifo')
local Protected = require('fibers.internal.protected')

local Socket = {}
local Listener = {}
Listener.__index = Listener
local Dial = {}
Dial.__index = Dial
local next_listener = 0
local next_dial = 0

local function current_owner(opts, label)
  local owner = opts.owner or Runtime.current_scope()
  if not owner then
    error(label .. ' requires opts.owner or a current Scope', 3)
  end
  if type(owner.admit_op) ~= 'function' then
    error(label .. ' owner must be a Scope or Region', 3)
  end
  return owner
end

local function region_of(owner)
  if owner and owner._fibers_scope and type(owner.raw_region) == 'function' then
    return owner:raw_region()
  end
  if owner and type(owner.admit_op) == 'function' and type(owner.release_op) == 'function' then
    return owner
  end
  return nil
end

local function masked_perform(rt, option)
  return rt:_perform_current(option, nil, true)
end

local function close_value(value, reason)
  if value and type(value.close) == 'function' then
    return value:close(reason)
  end
  return nil, HostError.unsupported('socket', 'close')
end

local function release_slot(rt, region, slot)
  local ok, err = Protected.pcall(function()
    return masked_perform(rt, region:release_op(slot))
  end)
  if not ok then
    return nil, err
  end
  return true
end

local function open_connection(rt, owner, handle, opts)
  local backend = HandleBackend.new(handle, {
    name = opts.name .. ':backend',
  })
  return masked_perform(
    rt,
    Stream.open_op(backend, {
      owner = owner,
      name = opts.name,
      read = true,
      write = true,
      read_capacity = opts.read_capacity or opts.capacity,
      write_capacity = opts.write_capacity or opts.capacity,
      read_chunk_size = opts.read_chunk_size or opts.chunk_size,
      write_chunk_size = opts.write_chunk_size or opts.chunk_size,
    })
  )
end

local function address(kind, fields)
  local out = {
    kind = kind,
    family = kind == 'unix' and 'unix' or 'inet',
  }
  for key, value in pairs(fields or {}) do
    out[key] = value
  end
  return out
end

function Socket.inet_address(host, port)
  return address('inet', {
    host = host or '0.0.0.0',
    port = port or 0,
  })
end

function Socket.unix_address(path)
  if type(path) ~= 'string' or path == '' then
    error('socket.unix_address expects a non-empty path', 2)
  end
  return address('unix', { path = path })
end

local function listener_settlement(listener)
  return Settlement.protocol({
    name = 'socket_listener',
    discharge_op = function(_ctx, _claim)
      return listener:close_op('scope settlement')
    end,
  })
end

function Listener:owned()
  return Owned.item(self, self._fibers_settle, {
    role = 'socket_listener',
    settle_name = 'socket_listener',
  })
end

function Listener:local_address()
  local h = self.host_listener
  if h and type(h.local_address) == 'function' then
    return h:local_address()
  end
  return self.address
end

local function terminal_accept(state)
  if state.kind == 'failed' then
    return nil, state.error
  end
  return nil, HostError.closed('socket', 'accept', {
    reason = state.reason,
  })
end

function Listener:accept_op()
  local listener = self
  local function wait()
    return listener.queue:snapshot_op():and_then(function(rows)
      if #rows > 0 then
        return listener.queue:get_op()
      end
      return Op.choice(listener.queue:get_op(), listener.done:terminal_op():map(terminal_accept))
    end)
  end
  return wait()
end

function Listener:close_op(reason)
  local listener = self
  return Op.always(true):wrap(function()
    if listener.closed then
      return listener.close_error == nil, listener.close_error
    end
    listener.closed = true
    local ok, err = true, nil
    if listener.host_listener then
      ok, err = close_value(listener.host_listener, reason)
    end
    listener.close_error = ok and nil
      or HostError.normalise(err, {
        domain = 'socket',
        action = 'close_listener',
        address = listener.address,
      })
    local rt = Runtime.current()
    if rt then
      if listener.driver then
        Protected.pcall(function()
          masked_perform(rt, listener.driver:request_cancel_op(reason or 'listener closed'))
        end)
      end
      Protected.pcall(function()
        masked_perform(rt, listener.done:publish_cancelled_op(reason or 'listener closed'))
      end)
    end
    if listener.close_error then
      return nil, listener.close_error
    end
    return true
  end)
end

function Listener:closed_op()
  local options = { self.done:terminal_op() }
  if self.driver then
    options[#options + 1] = self.driver:exit_op()
  end
  return Op.all(options):map(function()
    if self.close_error then
      return nil, self.close_error
    end
    return true
  end)
end

local function listener_driver(listener, opts)
  local rt = Runtime.current()
  local owner = listener.scope_owner
  local region = listener.region
  while not listener.closed do
    local ready, ready_err = Protected.pcall(function()
      return masked_perform(rt, listener.host_listener:read_ready_op())
    end)
    if not ready then
      if listener.closed then
        break
      end
      listener.close_error = HostError.normalise(ready_err, {
        domain = 'socket',
        action = 'wait_accept',
        address = listener.address,
      })
      break
    end
    if listener.closed then
      break
    end

    local slot = Adoption.slot(listener.name .. ':accepted-adoption')
    local admitted, admit_err = Protected.pcall(function()
      return masked_perform(rt, owner:admit_op(slot:owned({ role = 'accepted_socket_adoption' })))
    end)
    if not admitted then
      listener.close_error = HostError.normalise(admit_err, {
        domain = 'socket',
        action = 'admit_accepted_socket',
        address = listener.address,
      })
      break
    end

    local handle, peer, accept_err = listener.host_listener:accept()
    if not handle then
      release_slot(rt, region, slot)
      if HostError.is_would_block(accept_err) then
        -- A readiness notification is only a hint.
      elseif HostError.is(accept_err, 'closed') then
        break
      else
        listener.close_error = HostError.normalise(accept_err, {
          domain = 'socket',
          action = 'accept',
          address = listener.address,
        })
        break
      end
    else
      local adopted, adoption_err = slot:adopt(handle, close_value)
      if not adopted then
        release_slot(rt, region, slot)
        listener.close_error = adoption_err
        break
      end
      local connection
      local opened, open_err = Protected.pcall(function()
        connection = open_connection(rt, owner, handle, {
          name = listener.name .. ':connection',
          capacity = opts.capacity,
          read_capacity = opts.read_capacity,
          write_capacity = opts.write_capacity,
          chunk_size = opts.chunk_size,
          read_chunk_size = opts.read_chunk_size,
          write_chunk_size = opts.write_chunk_size,
        })
      end)
      if not opened then
        slot:close(open_err)
        release_slot(rt, region, slot)
        listener.close_error = HostError.normalise(open_err, {
          domain = 'socket',
          action = 'open_accepted_stream',
          address = listener.address,
        })
        break
      end
      connection.peer_address = peer
      connection.local_address = listener:local_address()
      local transferred, transfer_err = slot:release(handle)
      if not transferred then
        masked_perform(rt, connection:abort_op(transfer_err))
        release_slot(rt, region, slot)
        listener.close_error = transfer_err
        break
      end
      release_slot(rt, region, slot)
      masked_perform(rt, listener.queue:put_op(connection))
    end
  end

  if listener.close_error then
    Protected.pcall(function()
      masked_perform(rt, listener.done:publish_failure_op(listener.close_error))
    end)
  else
    Protected.pcall(function()
      masked_perform(rt, listener.done:publish_cancelled_op('listener closed'))
    end)
  end
end

local function listen_op(addr, opts)
  opts = opts or {}
  local owner = current_owner(opts, 'socket.listen_op')
  local region = region_of(owner)
  next_listener = next_listener + 1
  local name = opts.name or ('listener-' .. tostring(next_listener))
  local listener = Ownership.handle(name, {
    kind = 'socket_listener',
    address = addr,
    scope_owner = owner,
    region = region,
    queue = Queue.new({ capacity = opts.accept_capacity or 32, name = name .. ':accepted' }),
    done = Completion.new(name .. ':done'),
    adoption = Adoption.slot(name .. ':adoption'),
    host_listener = nil,
    driver = nil,
    closed = false,
    close_error = nil,
  })
  setmetatable(listener, Listener)
  listener._fibers_settle = listener_settlement(listener)

  return owner
    :admit_op(listener:owned())
    :and_then(function()
      return owner:admit_op(listener.adoption:owned({ role = 'listener_adoption' }))
    end)
    :wrap(function()
      local rt = Runtime.current()
      local host = opts.host or (rt and rt.host)
      if not host or type(host.create_listener) ~= 'function' then
        local err = HostError.unsupported('host', 'listen', { address = addr })
        masked_perform(rt, listener.done:publish_failure_op(err))
        release_slot(rt, region, listener.adoption)
        return nil, err
      end
      local host_listener, err = host:create_listener(addr, opts)
      if not host_listener then
        err = HostError.normalise(err, { domain = 'socket', action = 'listen', address = addr })
        masked_perform(rt, listener.done:publish_failure_op(err))
        release_slot(rt, region, listener.adoption)
        return nil, err
      end
      local adopted, adoption_err = listener.adoption:adopt(host_listener, close_value)
      if not adopted then
        masked_perform(rt, listener.done:publish_failure_op(adoption_err))
        return nil, adoption_err
      end
      if type(host_listener.bind_runtime) == 'function' then
        host_listener:bind_runtime(rt)
      end
      listener.host_listener = host_listener
      listener.address = listener:local_address() or addr
      listener.adoption:release(host_listener)
      release_slot(rt, region, listener.adoption)
      local ok, driver_or_err = Protected.pcall(function()
        return owner:spawn(function()
          return listener_driver(listener, opts)
        end, name .. ':accept-driver')
      end)
      if not ok then
        close_value(listener.host_listener, driver_or_err)
        local err = HostError.normalise(driver_or_err, {
          domain = 'socket',
          action = 'start_accept_driver',
          address = addr,
        })
        masked_perform(rt, listener.done:publish_failure_op(err))
        return nil, err
      end
      listener.driver = driver_or_err
      return listener
    end)
end

function Socket.listen_op(addr, opts)
  if type(addr) ~= 'table' then
    error('socket.listen_op expects an address value', 2)
  end
  return listen_op(addr, opts)
end

function Socket.listen_inet_op(host, port, opts)
  return listen_op(Socket.inet_address(host, port), opts)
end

function Socket.listen_unix_op(path, opts)
  return listen_op(Socket.unix_address(path), opts)
end

function Dial:connected_op()
  return self.completion:success_op()
end

function Dial:failed_op()
  return self.completion:failure_op()
end

function Dial:result_op()
  return self:connected_op():or_else(self:failed_op():map(function(err)
    return nil, err
  end))
end

function Dial:close_op(reason)
  if self.connection then
    return self.connection:abort_op(reason)
  end
  return Op.always(true)
end

local function dial_op(addr, opts)
  opts = opts or {}
  local owner = current_owner(opts, 'socket.dial_op')
  local region = region_of(owner)
  next_dial = next_dial + 1
  local name = opts.name or ('dial-' .. tostring(next_dial))
  local dial = setmetatable({
    name = name,
    address = addr,
    owner = owner,
    region = region,
    completion = Completion.new(name .. ':completion'),
    adoption = Adoption.slot(name .. ':adoption'),
    connection = nil,
  }, Dial)

  return owner:admit_op(dial.adoption:owned({ role = 'dial_adoption' })):wrap(function()
    local rt = Runtime.current()
    local host = opts.host or (rt and rt.host)
    if not host or type(host.dial_socket) ~= 'function' then
      local err = HostError.unsupported('host', 'dial', { address = addr })
      masked_perform(rt, dial.completion:publish_failure_op(err))
      return dial
    end
    local handle, peer, err = host:dial_socket(addr, opts)
    if not handle then
      err = HostError.normalise(err, { domain = 'socket', action = 'dial', address = addr })
      masked_perform(rt, dial.completion:publish_failure_op(err))
      release_slot(rt, region, dial.adoption)
      return dial
    end
    local adopted, adoption_err = dial.adoption:adopt(handle, close_value)
    if not adopted then
      masked_perform(rt, dial.completion:publish_failure_op(adoption_err))
      release_slot(rt, region, dial.adoption)
      return dial
    end
    local ok, connection_or_err = Protected.pcall(function()
      return open_connection(rt, owner, handle, {
        name = name .. ':connection',
        capacity = opts.capacity,
        read_capacity = opts.read_capacity,
        write_capacity = opts.write_capacity,
        chunk_size = opts.chunk_size,
        read_chunk_size = opts.read_chunk_size,
        write_chunk_size = opts.write_chunk_size,
      })
    end)
    if not ok then
      dial.adoption:close(connection_or_err)
      release_slot(rt, region, dial.adoption)
      local normal = HostError.normalise(connection_or_err, {
        domain = 'socket',
        action = 'open_connection',
        address = addr,
      })
      masked_perform(rt, dial.completion:publish_failure_op(normal))
      return dial
    end
    dial.connection = connection_or_err
    dial.connection.peer_address = peer or addr
    dial.adoption:release(handle)
    release_slot(rt, region, dial.adoption)
    masked_perform(rt, dial.completion:publish_success_op(dial.connection))
    return dial
  end)
end

function Socket.dial_op(addr, opts)
  if type(addr) ~= 'table' then
    error('socket.dial_op expects an address value', 2)
  end
  return dial_op(addr, opts)
end

function Socket.dial_inet_op(host, port, opts)
  opts = opts or {}
  if opts.bind_host ~= nil or opts.bind_port ~= nil then
    opts = setmetatable({
      local_address = Socket.inet_address(opts.bind_host or '0.0.0.0', opts.bind_port or 0),
    }, { __index = opts })
  end
  return dial_op(Socket.inet_address(host, port), opts)
end

function Socket.dial_unix_op(path, opts)
  return dial_op(Socket.unix_address(path), opts)
end

Socket.Listener = Listener
Socket.Dial = Dial
Socket.Error = HostError
return Socket
