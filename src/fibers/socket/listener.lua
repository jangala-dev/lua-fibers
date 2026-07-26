-- Scoped socket listener facility.
--
-- A Listener is one running Lifetime under custody. Its Task and private Scope are
-- capability views over that Lifetime, and accepted Streams remain in its private
-- custody until acceptance atomically transfers a complete subtree.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local HostHold = require('fibers.internal.lifetime.host_hold')
local IO = require('fibers.host.io')
local IOAudit = require('fibers.diagnostics.io')
local Lifecycle = require('fibers.socket.lifecycle')
local Lifetime = require('fibers.lifetime')
local Task = require('fibers.task')
local Scope = require('fibers.scope')
local Connection = require('fibers.socket.connection')
local Closure = require('fibers.closure')
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

local function listener_closure(listener)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return listener:close_op(reason or 'scope closure')
  end, function()
    return listener:closed_op()
  end, {
    name = 'listener',
    finish_result = Closure.require_ok('listener closure failed'),
  })
end

function Listener:lifetime()
  return self._lifetime
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

local function accept_to_scope_op(listener, target_scope)
  local accepted = listener.queue:get_op():and_then(function(connection)
    local runtime = listener._lifetime.runtime
    local source_lifetime = runtime and runtime.lifetimes:current_custodian(connection)
    if not source_lifetime then
      return Op.never()
    end
    local source_scope = Scope.for_lifetime(source_lifetime)
    return source_scope:move_op(connection, target_scope):map(function()
      return connection
    end)
  end)

  -- Queued input has certified priority over terminal listener state.
  return accepted:or_else(listener.lifecycle:unavailable_op():map(terminal_accept))
end

function Listener:accept_op(target)
  local listener = self
  return IO.with_target_scope_op(
    target,
    'Listener:accept_op expects a target Scope, or a current Scope',
    function(scope)
      return accept_to_scope_op(listener, scope)
    end
  )
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
  local cancel = listener._task:request_cancel_op(reason)
  return listener.lifecycle
    :request_stop_op(reason)
    :and_then(function(first, state)
      if first then
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
  return IO.closed_after_driver_op(self._task, self.lifecycle:terminal_op():map(listener_close_result))
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
  local ok, driver_err = Protected.pcall(function()
    local host_listener = perform(listener.lifecycle:start_result_op())
    if not host_listener then
      return
    end

    while true do
      perform(host_listener:read_ready_op())

      local host_hold = HostHold.new(listener.name .. ':accepted-host-hold')
      perform(driver_scope:admit_op(host_hold))

      local handle, peer, accept_err = host_listener:accept()
      if not handle then
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
        local held, hold_err = host_hold:hold('socket', handle, close_socket)
        if not held then
          error(hold_err, 0)
        end

        local connection, connection_err =
          Connection.from_host_hold(rt, driver_scope, host_hold, 'socket', handle, {
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
  local scope = IO.current_scope(opts, 'socket.listen_op')
  next_listener = next_listener + 1
  local name = opts.name or ('listener-' .. tostring(next_listener))
  local parent_scope = IO.require_scope(scope, 'socket.listen_op')
  local listener = setmetatable({
    kind = 'socket_listener',
    name = name,
    address = address,
    queue = Queue.new({ capacity = opts.accept_capacity or 32, name = name .. ':accepted' }),
    lifecycle = ListenerLifecycle.new(name, address),
    host_hold = HostHold.new(name .. ':host-hold'),
  }, Listener)
  Lifetime.define(listener, {
    name = name,
    role = 'socket_listener',
    closure = listener_closure(listener),
    children = { listener.host_hold },
  })
  local private_scope = Scope.for_lifetime(listener._lifetime)
  listener._task = Task._new(function()
    return private_scope:run(function(driver_scope)
      return driver(listener, driver_scope, opts)
    end)
  end, name, parent_scope, { lifetime = listener._lifetime, closure = parent_scope.closure })

  return scope
    :admit_op(listener)
    :and_then(function()
      return listener._task:spawn_effect_op()
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

      local held, hold_err = listener.host_hold:hold('listener', host_listener, close_socket)
      if not held then
        IO.masked_perform(rt, listener.lifecycle:start_failed_op(hold_err, true))
        return nil, hold_err
      end

      if type(host_listener.bind_runtime) == 'function' then
        host_listener:bind_runtime(rt)
      end
      local local_address = type(host_listener.local_address) == 'function' and host_listener:local_address()
        or address

      IOAudit.transfer(host_listener, listener, { kind = 'host_handle', role = 'listener' })
      local released, release_err = listener.host_hold:release('listener', host_listener)
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
