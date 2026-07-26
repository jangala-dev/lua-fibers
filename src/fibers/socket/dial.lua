-- Scoped outbound socket dial facility.
--
-- A Dial owns its driver and any successful Stream not yet taken. Taking a
-- connection commits its lifecycle transition and custody transfer together.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local HostHold = require('fibers.internal.lifetime.host_hold')
local IO = require('fibers.host.io')
local DialLifecycle = require('fibers.socket.dial_lifecycle')
local Lifetime = require('fibers.lifetime')
local Task = require('fibers.task')
local Scope = require('fibers.scope')
local Connection = require('fibers.socket.connection')
local Closure = require('fibers.closure')
local Protected = require('fibers.internal.protected')
local perform = require('fibers.perform')

local Module = {}
local Dial = {}
Dial.__index = Dial
local next_dial = 0

local function close_socket(value, reason)
  return IO.close_value('socket', value, reason)
end

local function dial_closure(dial)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return dial:close_op(reason or 'scope closure')
  end, function()
    return dial:closed_op()
  end, {
    name = 'dial',
    finish_result = Closure.require_ok('dial closure failed'),
  })
end

function Dial:lifetime()
  return self._lifetime
end

function Dial:state_op()
  return self.lifecycle:state_op()
end

function Dial:state_value()
  return self.lifecycle:state_value()
end

local function connected_to_scope_op(dial, scope)
  return dial.lifecycle:take_op():and_then(function(connection, source_scope)
    return source_scope:move_op(connection, scope):map(function()
      return connection
    end)
  end)
end

function Dial:connected_op(target)
  local dial = self
  return IO.with_target_scope_op(
    target,
    'Dial connection transfer expects a target Scope, or a current Scope',
    function(scope)
      return connected_to_scope_op(dial, scope)
    end
  )
end

function Dial:failed_op()
  return self.lifecycle:failure_op()
end

function Dial:result_op(target)
  return self:connected_op(target):or_else(self:failed_op():map(function(err)
    return nil, err
  end))
end

function Dial:close_op(reason)
  local dial = self
  reason = reason or 'dial closed'
  local cancel = dial._task:request_cancel_op(reason)
  return dial.lifecycle:request_close_op(reason):and_then(function(first)
    if first then
      return cancel:map(function()
        return true
      end)
    end
    return Op.always(true)
  end, Op.dependencies(cancel))
end

local function closed_result(state)
  if state.fatal and state.error then
    return nil, state.error
  end
  return true
end

function Dial:closed_op()
  return IO.closed_after_driver_op(self._task, self.lifecycle:terminal_op():map(closed_result))
end

local function driver(dial, driver_scope, opts)
  local rt = Runtime.current()
  local ok, driver_err = Protected.pcall(function()
    local host_hold = HostHold.new(dial.name .. ':host-hold')
    perform(driver_scope:admit_op(host_hold))

    local host = opts.host or (rt and rt.host)
    local start_dial = host and host.start_dial
    if type(start_dial) ~= 'function' then
      local err = HostError.unsupported('host', 'dial', { address = dial.address })
      IO.masked_perform(rt, dial.lifecycle:publish_failure_op(err))
      return
    end

    local handle, err = start_dial(host, dial.address, opts)
    if not handle then
      err = HostError.normalise(err, {
        domain = 'socket',
        action = 'dial',
        address = dial.address,
      })
      IO.masked_perform(rt, dial.lifecycle:publish_failure_op(err))
      return
    end

    local held, hold_err = host_hold:hold('socket', handle, close_socket)
    if not held then
      error(hold_err, 0)
    end

    if type(handle.bind_runtime) == 'function' then
      handle:bind_runtime(rt)
    end

    if type(handle.finish_connect) == 'function' then
      -- A non-blocking connect which returned EINPROGRESS must first become
      -- writable before SO_ERROR is authoritative. Immediate connections skip
      -- this wait through _connect_complete.
      if handle._connect_pending and not handle._connect_complete then
        perform(handle:write_ready_op())
      end
      while true do
        local connected, connected_peer, finish_err = handle:finish_connect()
        if connected then
          handle = connected
          peer = connected_peer or peer
          break
        end
        if not HostError.is_would_block(finish_err) then
          host_hold:close(finish_err)
          IO.masked_perform(
            rt,
            dial.lifecycle:publish_failure_op(HostError.normalise(finish_err, {
              domain = 'socket',
              action = 'connect_finish',
              address = dial.address,
            }))
          )
          return
        end
        perform(handle:write_ready_op())
      end
    end

    local connection, connection_err =
      Connection.from_host_hold(rt, driver_scope, host_hold, 'socket', handle, {
        name = dial.name .. ':connection',
        capacity = opts.capacity,
        read_capacity = opts.read_capacity,
        write_capacity = opts.write_capacity,
        chunk_size = opts.chunk_size,
        read_chunk_size = opts.read_chunk_size,
        write_chunk_size = opts.write_chunk_size,
        action = 'open_connection',
        address = dial.address,
        peer_address = peer,
        default_peer = dial.address,
      })
    if not connection then
      error(connection_err, 0)
    end

    local published, state =
      IO.masked_perform(rt, dial.lifecycle:publish_connected_op(connection, driver_scope))
    if not published then
      if state.kind == 'closing' or state.kind == 'closed' then
        return
      end
      error(
        HostError.protocol('socket', 'publish_connected', 'Dial lifecycle rejected a connected Stream', {
          address = dial.address,
          state = state.kind,
        }),
        0
      )
    end

    -- Retain the child scope, and therefore the untaken connection, until
    -- take or closure makes the lifecycle terminal for the driver.
    perform(dial.lifecycle:driver_release_op())
  end)

  if ok then
    local state = dial.lifecycle:state_value()
    if state.kind == 'closing' then
      IO.masked_perform(rt, dial.lifecycle:closed_op(state.reason))
    end
    return
  end

  if Runtime.is_cancelled(driver_err) then
    local closed = HostError.closed('socket', 'dial', {
      reason = driver_err.reason or 'dial cancelled',
      address = dial.address,
    })
    IO.masked_perform(rt, dial.lifecycle:closed_op(driver_err.reason or 'dial cancelled', closed, false))
    return
  end

  local failure
  local fatal = false
  if HostError.is(driver_err) then
    failure = driver_err
  else
    failure = IO.protocol_error('socket', 'dial_driver', driver_err, {
      address = dial.address,
    })
    fatal = true
  end

  local state = dial.lifecycle:state_value()
  if state.kind == 'closing' then
    IO.masked_perform(rt, dial.lifecycle:closed_op(state.reason, failure, fatal))
  else
    IO.masked_perform(rt, dial.lifecycle:publish_failure_op(failure, fatal))
  end
end

function Module.dial_op(address, opts)
  opts = IO.copy_table(opts)
  if type(opts.local_address) == 'table' then
    opts.local_address = IO.copy_table(opts.local_address)
  end
  local scope = IO.current_scope(opts, 'socket.dial_op')
  next_dial = next_dial + 1
  local name = opts.name or ('dial-' .. tostring(next_dial))
  local parent_scope = IO.require_scope(scope, 'socket.dial_op')
  local dial = setmetatable({
    kind = 'socket_dial',
    name = name,
    address = address,
    lifecycle = DialLifecycle.new(name, address),
  }, Dial)
  Lifetime.define(dial, {
    name = name,
    role = 'socket_dial',
    closure = dial_closure(dial),
  })
  local private_scope = Scope.for_lifetime(dial._lifetime)
  dial._task = Task._new(function()
    return private_scope:run(function(driver_scope)
      return driver(dial, driver_scope, opts)
    end)
  end, name, parent_scope, { lifetime = dial._lifetime, closure = parent_scope.closure })

  return scope
    :admit_op(dial)
    :and_then(function()
      return dial._task:spawn_effect_op()
    end, false)
    :map(function()
      return dial
    end)
end

function Dial:connected(target)
  return perform(self:connected_op(target))
end

function Dial:failed()
  return perform(self:failed_op())
end

function Dial:result(target)
  return perform(self:result_op(target))
end

function Dial:close(reason)
  return perform(self:close_op(reason))
end

function Dial:closed()
  return perform(self:closed_op())
end

Module.Dial = Dial
return Module
