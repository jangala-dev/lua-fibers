-- Scoped socket listener facility.
--
-- A Listener owns its accept driver and all accepted Streams until acceptance
-- atomically transfers one complete Stream subtree into the target scope.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local Adoption = require('fibers.lifetime.adoption')
local IO = require('fibers.host.io')
local IOAudit = require('fibers.diagnostics.io')
local Lifecycle = require('fibers.socket.lifecycle')
local Connection = require('fibers.socket.connection')
local Ownership = require('fibers.lifetime.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.lifetime.settlement')
local Queue = require('fibers.resource.queue')
local Protected = require('fibers.internal.protected')
local perform = require('fibers.perform')

local ListenerLifecycle = Lifecycle.define({
  prefix = 'socket.listener',
  error_domain = 'socket',
  start_action = 'listen',
  start_failed_reason = 'listener start failed',
  closed_reason = 'listener closed',
})

local Module = {}
local Listener = {}
Listener.__index = Listener
local next_listener = 0

local function close_socket(value, reason)
  return IO.close_value('socket', value, reason)
end

local function listener_settlement(listener)
  return Settlement.request_then_wait(function(_ctx, _record, reason)
    return listener:close_op(reason or 'scope settlement')
  end, function()
    return listener:closed_op():and_then(function(ok, err)
      if not ok then
        error(err or 'listener settlement failed', 0)
      end
      return Op.always(true)
    end)
  end)
end

function Listener:owned(children)
  return Owned.tree(self, self._fibers_settle, children or {}, {
    role = 'socket_listener',
    settle_name = 'socket_listener',
  })
end

function Listener:state_op()
  return self.lifecycle:state_op()
end

function Listener:state_value()
  return self.lifecycle:state_value()
end

function Listener:local_address()
  local state = self.lifecycle:state_value()
  return state.address or self.address
end

function Listener:host_handle()
  return self.lifecycle:state_value().handle
end

local function terminal_accept(state)
  if state.error then
    return nil, state.error
  end
  return nil,
    HostError.closed('socket', 'accept', {
      reason = state.reason,
      address = state.address,
    })
end

function Listener:accept_op(target)
  local target_region = IO.region_of(target or Runtime.current_scope())
  if not target_region then
    error('Listener:accept_op expects a target Scope or Region, or a current Scope', 2)
  end

  local accepted = self.queue:get_op():and_then(function(connection)
    local source_region = IO.region_of(connection.owner)
    if not source_region then
      return Op.never()
    end
    return source_region:move_op(connection, target_region):map(function()
      return connection
    end)
  end)

  -- Queued input has certified priority over terminal listener state.
  return accepted:or_else(self.lifecycle:unavailable_op():map(terminal_accept))
end

local function listener_close_result(state)
  local err = state.close_error or (state.fatal and state.error or nil)
  if err then
    return nil, err
  end
  return true
end

function Listener:close_op(reason)
  local listener = self
  reason = reason or 'listener closed'
  local cancel = listener.driver and listener.driver:request_cancel_op(reason) or Op.always(true)
  return listener.lifecycle
    :request_stop_op(reason)
    :and_then(function(first, state)
      if first and listener.driver then
        return cancel:map(function()
          return first, state
        end)
      end
      return Op.always(first, state)
    end, cancel)
    :wrap(function(first, state)
      if first and state.handle then
        local ok, close_err = IO.safe_close('socket', state.handle, reason, {
          domain = 'socket',
          action = 'close_listener',
          address = state.address,
        })
        if not ok then
          local rt = Runtime.current()
          if rt then
            IO.masked_perform(rt, listener.lifecycle:record_close_error_op(close_err))
          end
        end
      end
      return listener_close_result(listener.lifecycle:state_value())
    end)
end

function Listener:closed_op()
  local joined = self.driver and self.driver:exit_op() or Op.always(true)
  local lifecycle = self.lifecycle
  local terminal = lifecycle:terminal_op()
  return joined:and_then(function()
    return terminal:map(listener_close_result)
  end, terminal)
end

local function close_from_driver(listener, rt, reason, err, fatal)
  local first, state = IO.masked_perform(rt, listener.lifecycle:request_stop_op(reason, err, fatal))
  if first and state.handle then
    local ok, close_err = IO.safe_close('socket', state.handle, reason, {
      domain = 'socket',
      action = 'close_listener',
      address = state.address,
    })
    if not ok then
      IO.masked_perform(rt, listener.lifecycle:record_close_error_op(close_err))
    end
  end
  IO.masked_perform(rt, listener.lifecycle:stopped_op(reason, err, fatal))
end

local function driver(listener, driver_scope, opts)
  local rt = Runtime.current()
  local driver_region = IO.region_of(driver_scope)
  local ok, driver_err = Protected.pcall(function()
    local host_listener = perform(listener.lifecycle:start_result_op())
    if not host_listener then
      return
    end

    while true do
      perform(host_listener:read_ready_op())

      local slot = Adoption.slot(listener.name .. ':accepted-adoption')
      perform(driver_scope:admit_op(slot:owned({ role = 'accepted_socket_adoption' })))

      local handle, peer, accept_err = host_listener:accept()
      if not handle then
        IO.release_owned(rt, driver_region, slot)
        if HostError.is_would_block(accept_err) then
          -- Readiness is only a hint.
        elseif HostError.is(accept_err, 'closed') then
          break
        else
          error(
            HostError.normalise(accept_err, {
              domain = 'socket',
              action = 'accept',
              address = listener:local_address(),
            }),
            0
          )
        end
      else
        local adopted, adoption_err = slot:adopt(handle, close_socket)
        if not adopted then
          IO.release_owned(rt, driver_region, slot)
          error(adoption_err, 0)
        end

        local connection, connection_err = Connection.adopt(rt, driver_scope, driver_region, slot, handle, {
          name = listener.name .. ':connection',
          capacity = opts.capacity,
          read_capacity = opts.read_capacity,
          write_capacity = opts.write_capacity,
          chunk_size = opts.chunk_size,
          read_chunk_size = opts.read_chunk_size,
          write_chunk_size = opts.write_chunk_size,
          action = 'open_accepted_stream',
          address = listener:local_address(),
          local_address = listener:local_address(),
          peer_address = peer,
        })
        if not connection then
          error(connection_err, 0)
        end

        -- Queue-space waits remain cancellable; the connection is already
        -- covered by driver-scope custody.
        perform(listener.queue:put_op(connection))
      end
    end
  end)

  if ok then
    close_from_driver(listener, rt, 'listener driver stopped')
    return
  end

  if Runtime.is_cancelled(driver_err) then
    close_from_driver(listener, rt, driver_err.reason or 'listener cancelled')
    return
  end

  local failure
  local fatal = false
  if HostError.is(driver_err) then
    failure = driver_err
  else
    failure = IO.protocol_error('socket', 'accept_driver', driver_err, {
      address = listener:local_address(),
    })
    fatal = true
  end
  close_from_driver(listener, rt, 'listener driver failed', failure, fatal)
end

function Module.listen_op(address, opts)
  opts = IO.copy_table(opts)
  local owner = IO.current_owner(opts, 'socket.listen_op')
  next_listener = next_listener + 1
  local name = opts.name or ('listener-' .. tostring(next_listener))
  local listener = Ownership.handle(name, {
    kind = 'socket_listener',
    address = address,
    scope_owner = owner,
    queue = Queue.new({ capacity = opts.accept_capacity or 32, name = name .. ':accepted' }),
    lifecycle = ListenerLifecycle.new(name, address),
    adoption = Adoption.slot(name .. ':adoption'),
    driver = nil,
  })
  setmetatable(listener, Listener)
  listener._fibers_settle = listener_settlement(listener)

  local driver_parent = IO.scope_for_owner(owner, 'socket.listen_op')
  listener.driver = IO.new_driver_task(driver_parent, name .. ':accept-driver', function(driver_scope)
    return driver(listener, driver_scope, opts)
  end)

  local owned = listener:owned({
    listener.adoption:owned({ role = 'listener_adoption' }),
    listener.driver:owned(),
  })

  return owner
    :admit_op(owned)
    :and_then(function()
      return listener.driver:spawn_effect_op()
    end, false)
    :wrap(function()
      local rt = Runtime.current()
      local host = opts.host or (rt and rt.host)
      if not host or type(host.create_listener) ~= 'function' then
        local err = HostError.unsupported('host', 'listen', { address = address })
        IO.masked_perform(rt, listener.lifecycle:start_failed_op(err))
        return nil, err
      end

      local called, host_listener, err = Protected.pcall(function()
        return host:create_listener(address, opts)
      end)
      if not called then
        local failure = IO.protocol_error('socket', 'listen', host_listener, { address = address })
        IO.masked_perform(rt, listener.lifecycle:start_failed_op(failure, true))
        error(failure, 0)
      end
      if not host_listener then
        err = HostError.normalise(err, { domain = 'socket', action = 'listen', address = address })
        IO.masked_perform(rt, listener.lifecycle:start_failed_op(err))
        return nil, err
      end

      local adopted, adoption_err = listener.adoption:adopt(host_listener, close_socket)
      if not adopted then
        IO.masked_perform(rt, listener.lifecycle:start_failed_op(adoption_err, true))
        return nil, adoption_err
      end

      if type(host_listener.bind_runtime) == 'function' then
        host_listener:bind_runtime(rt)
      end
      local local_address = type(host_listener.local_address) == 'function' and host_listener:local_address()
        or address

      IOAudit.transfer(host_listener, listener, { kind = 'host_handle', role = 'listener' })
      local released, release_err = listener.adoption:release(host_listener)
      if not released then
        close_socket(host_listener, release_err)
        IO.masked_perform(rt, listener.lifecycle:start_failed_op(release_err, true))
        return nil, release_err
      end

      local activated =
        IO.masked_perform(rt, listener.lifecycle:activate_op(host_listener, local_address or address))
      if not activated then
        close_socket(host_listener, 'listener lifecycle no longer accepts activation')
        return nil,
          HostError.closed('socket', 'listen', {
            reason = 'listener closed before activation',
            address = address,
          })
      end
      return listener
    end)
end

function Listener:accept(target)
  return perform(self:accept_op(target))
end

function Listener:close(reason)
  return perform(self:close_op(reason))
end

function Listener:closed()
  return perform(self:closed_op())
end

Module.Listener = Listener
return Module
