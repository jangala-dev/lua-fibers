-- Scoped socket listener facility.
--
-- A Listener is one running Lifetime under custody. Its reactor-owned accept
-- source is a child of its private Scope, and accepted descriptors remain in the
-- listener's hold until acceptance atomically constructs and transfers a Stream.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local HostError = require('fibers.host.error')
local HostHold = require('fibers.internal.lifetime.host_hold')
local IO = require('fibers.host.io')
local Activation = require('fibers.socket.activation')
local Lifecycle = require('fibers.socket.lifecycle')
local Connection = require('fibers.socket.connection')
local Closure = require('fibers.closure')
local HostOffer = require('fibers.host.offer')
local Lifetime = require('fibers.lifetime')
local Scope = require('fibers.scope')
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

local function accept_to_scope_op(listener, target_scope)
  local accepted = listener.offers:result_op():wrap(function(offer, source_err)
    if not offer then
      return nil, source_err
    end
    local rt = Runtime.current()
    local connection, err = Connection.from_host_hold(
      rt,
      target_scope,
      listener.accepted_hold,
      offer.key,
      offer.handle,
      Connection.options(listener.options, {
        name = listener.name .. ':connection',
        action = 'open_accepted_stream',
        address = listener:local_address(),
        local_address = listener:local_address(),
        peer_address = offer.peer,
      })
    )
    return connection, err
  end)

  return accepted
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
  reason = reason or 'listener closed'
  return self.lifecycle:request_stop_op(reason):wrap(function(first, state)
    if self.offers then
      local requested, request_err = perform(self.offers:close_op(reason))
      if not requested then
        return nil, request_err
      end
      local source_closed, source_err = perform(self.offers:closed_op())
      if not source_closed then
        return nil, source_err
      end
      local owns_source = perform(self.private_scope:has_custody_op(self.offers))
      if owns_source then
        local retired, retire_err = perform(self.private_scope:close_op(self.offers, reason))
        if not retired then
          return nil, retire_err
        end
      end
    end
    return true, state
  end)
end

function Listener:closed_op()
  local terminal = self.lifecycle:terminal_op()
  if not self.offers then
    return terminal:map(listener_close_result)
  end
  local source_closed = self.offers:closed_op()
  return source_closed:and_then(function(ok, source_err)
    if not ok then
      return Op.always(nil, source_err)
    end
    return terminal:map(listener_close_result)
  end, Op.dependencies(source_closed, terminal))
end

local function retire_listener(listener, rt, source_state)
  local reason = source_state.reason or 'listener offer source stopped'
  local err = source_state.kind == 'failed' and source_state.error or nil
  local fatal = err ~= nil and not HostError.is(err)
  local first, state = IO.masked_perform(rt, listener.lifecycle:request_stop_op(reason, err, fatal))
  local close_error
  if state.handle and not listener.handle_closed then
    listener.handle_closed = true
    local ok, close_err = IO.safe_close('socket', state.handle, reason, {
      domain = 'socket',
      action = 'close_listener',
      address = state.address,
    })
    if not ok then
      close_error = close_err
      IO.masked_perform(rt, listener.lifecycle:record_close_error_op(close_err))
    end
  end
  IO.masked_perform(rt, listener.lifecycle:stopped_op(reason, err, fatal or close_error ~= nil))
  if close_error then
    return nil, close_error
  end
  return true
end

local function accepted_offers(listener, opts)
  return HostOffer.new({
    name = listener.name .. ':accepted',
    domain = 'socket',
    action = 'accept',
    role = 'socket_accept_source',
    capacity = opts.accept_capacity or 32,
    handle = function()
      return listener:host_handle()
    end,
    mode = 'read',
    pull = function(registered_handle)
      local handle, peer, accept_err = registered_handle:accept()
      if not handle then
        return nil, accept_err
      end

      listener.accepted_seq = listener.accepted_seq + 1
      local key = 'accepted-' .. tostring(listener.accepted_seq)
      local held, hold_err = listener.accepted_hold:hold(key, handle, close_socket)
      if not held then
        error(hold_err, 0)
      end
      return { key = key, handle = handle, peer = peer }
    end,
    dispose = function(offer, reason)
      if type(offer) ~= 'table' then
        return
      end
      local discarded, discard_err =
        listener.accepted_hold:discard(offer.key, offer.handle, reason or 'accepted offer discarded')
      if not discarded then
        error(discard_err, 0)
      end
    end,
    closed_error = function(err)
      return HostError.closed('socket', 'accept', {
        reason = err and err.reason or 'listener closed',
        address = listener:local_address(),
      })
    end,
    retired = function(rt, state)
      return retire_listener(listener, rt, state)
    end,
  })
end

function Module.listen_op(address, opts)
  opts = IO.copy_table(opts)
  local scope = IO.current_scope(opts, 'socket.listen_op')
  next_listener = next_listener + 1
  local name = opts.name or ('listener-' .. tostring(next_listener))
  local listener = setmetatable({
    kind = 'socket_listener',
    name = name,
    address = address,
    lifecycle = ListenerLifecycle.new(name, address),
    host_hold = HostHold.new(name .. ':host-hold'),
    accepted_hold = HostHold.new(name .. ':accepted-host-hold'),
    accepted_seq = 0,
    options = opts,
  }, Listener)

  Lifetime.define(listener, {
    name = name,
    role = 'socket_listener',
    closure = listener_closure(listener),
    children = { listener.host_hold, listener.accepted_hold },
  })
  local private_scope = Scope.for_lifetime(listener._lifetime)
  listener.private_scope = private_scope

  return scope:admit_op(listener):wrap(function()
    local active, activation_err = Activation.create(listener, {
      host = opts.host,
      host_method = 'create_listener',
      options = opts,
      lifecycle = listener.lifecycle,
      hold = listener.host_hold,
      hold_key = 'listener',
      close = close_socket,
      domain = 'socket',
      action = 'listen',
      role = 'listener',
      address = address,
      closed_reason = 'listener lifecycle no longer accepts activation',
      closed_message = 'listener closed before activation',
    })
    if not active then
      return nil, activation_err
    end

    listener.offers = accepted_offers(listener, opts)
    local opened, open_err = perform(listener.offers:open_op(private_scope))
    if not opened then
      retire_listener(listener, Runtime.current(), {
        kind = 'failed',
        reason = 'listener offer source failed to open',
        error = open_err,
      })
      return nil, open_err
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
