-- Scoped outbound socket dial facility.
--
-- A Dial owns its driver and any successful but unclaimed Stream. Claiming a
-- connection commits its lifecycle transition and custody transfer together.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local Adoption = require('fibers.lifetime.adoption')
local IO = require('fibers.host.io')
local DialLifecycle = require('fibers.socket.dial_lifecycle')
local Connection = require('fibers.socket.connection')
local Ownership = require('fibers.lifetime.ownership')
local Owned = require('fibers.lifetime.region').Owned
local Settlement = require('fibers.lifetime.settlement')
local Protected = require('fibers.internal.protected')
local perform = require('fibers.perform')

local Module = {}
local Dial = {}
Dial.__index = Dial
local next_dial = 0

local function close_socket(value, reason)
  return IO.close_value('socket', value, reason)
end

local function dial_settlement(dial)
  return Settlement.request_then_wait(function(_ctx, _record, reason)
    return dial:close_op(reason or 'scope settlement')
  end, function()
    return dial:closed_op():and_then(function(ok, err)
      if not ok then
        error(err or 'dial settlement failed', 0)
      end
      return Op.always(true)
    end)
  end)
end

function Dial:owned(children)
  return Owned.tree(self, self._fibers_settle, children or {}, {
    role = 'socket_dial',
    settle_name = 'socket_dial',
  })
end

function Dial:state_op()
  return self.lifecycle:state_op()
end

function Dial:state_value()
  return self.lifecycle:state_value()
end

local function target_region(target)
  local region = IO.region_of(target or Runtime.current_scope())
  if not region then
    error('Dial connection transfer expects a target Scope or Region, or a current Scope', 3)
  end
  return region
end

function Dial:connected_op(target)
  local region = target_region(target)
  return self.lifecycle:claim_op():and_then(function(connection, source_region)
    return source_region:move_op(connection, region):map(function()
      return connection
    end)
  end)
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
  local cancel = dial.driver and dial.driver:request_cancel_op(reason) or Op.always(true)
  return dial.lifecycle:request_close_op(reason):and_then(function(first)
    if first and dial.driver then
      return cancel:map(function()
        return true
      end)
    end
    return Op.always(true)
  end, cancel)
end

local function closed_result(state)
  if state.fatal and state.error then
    return nil, state.error
  end
  return true
end

function Dial:closed_op()
  local joined = self.driver and self.driver:exit_op() or Op.always(true)
  local lifecycle = self.lifecycle
  local terminal = lifecycle:terminal_op()
  return joined:and_then(function()
    return terminal:map(closed_result)
  end, terminal)
end

local function driver(dial, driver_scope, opts)
  local rt = Runtime.current()
  local driver_region = IO.region_of(driver_scope)
  local ok, driver_err = Protected.pcall(function()
    local slot = Adoption.slot(dial.name .. ':adoption')
    perform(driver_scope:admit_op(slot:owned({ role = 'dial_adoption' })))

    local host = opts.host or (rt and rt.host)
    local start_dial = host and host.start_dial
    local legacy_dial = host and host.dial_socket
    if type(start_dial) ~= 'function' and type(legacy_dial) ~= 'function' then
      local err = HostError.unsupported('host', 'dial', { address = dial.address })
      IO.release_owned(rt, driver_region, slot)
      IO.masked_perform(rt, dial.lifecycle:publish_failure_op(err))
      return
    end

    local handle, peer, err
    if type(start_dial) == 'function' then
      handle, err = start_dial(host, dial.address, opts)
    else
      handle, peer, err = legacy_dial(host, dial.address, opts)
    end
    if not handle then
      IO.release_owned(rt, driver_region, slot)
      err = HostError.normalise(err, {
        domain = 'socket',
        action = 'dial',
        address = dial.address,
      })
      IO.masked_perform(rt, dial.lifecycle:publish_failure_op(err))
      return
    end

    local adopted, adoption_err = slot:adopt(handle, close_socket)
    if not adopted then
      IO.release_owned(rt, driver_region, slot)
      error(adoption_err, 0)
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
          slot:close(finish_err)
          IO.release_owned(rt, driver_region, slot)
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

    local connection, connection_err = Connection.adopt(rt, driver_scope, driver_region, slot, handle, {
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
      IO.masked_perform(rt, dial.lifecycle:publish_connected_op(connection, driver_region))
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

    -- Retain the child scope, and therefore the unclaimed connection, until
    -- claim or closure makes the lifecycle terminal for the driver.
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
  local owner = IO.current_owner(opts, 'socket.dial_op')
  next_dial = next_dial + 1
  local name = opts.name or ('dial-' .. tostring(next_dial))
  local dial = Ownership.handle(name, {
    kind = 'socket_dial',
    address = address,
    scope_owner = owner,
    lifecycle = DialLifecycle.new(name, address),
    driver = nil,
  })
  setmetatable(dial, Dial)
  dial._fibers_settle = dial_settlement(dial)
  dial._fibers_settle_name = 'socket_dial'

  local driver_parent = IO.scope_for_owner(owner, 'socket.dial_op')
  dial.driver = IO.new_driver_task(driver_parent, name .. ':driver', function(driver_scope)
    return driver(dial, driver_scope, opts)
  end)

  return owner
    :admit_op(dial:owned({ dial.driver:owned() }))
    :and_then(function()
      return dial.driver:spawn_effect_op()
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
