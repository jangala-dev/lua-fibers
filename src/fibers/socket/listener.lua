-- Scoped socket listener facility.
--
-- A Listener is one running Lifetime under custody. Its reactor-owned accept
-- source is a child of its private Scope, and accepted descriptors remain in the
-- listener's hold until acceptance atomically constructs and transfers a Stream.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Address = require('fibers.net.address')
local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
local Activation = require('fibers.socket.activation')
local Lifecycle = require('fibers.socket.lifecycle')
local Connection = require('fibers.socket.connection')
local HostOffer = require('fibers.io.offer')
local Lifetime = require('fibers.lifetime')
local Scope = require('fibers.scope')
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

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

local LISTEN_OPTIONS = {
  scope = true, host = true, label = Contract.non_empty_string,
  accept_capacity = Contract.positive_integer, backlog = Contract.positive_integer,
  reuse_address = Contract.boolean, unlink_existing = Contract.boolean,
  unlink_on_close = Contract.boolean, nodelay = Contract.boolean,
  capacity = Contract.positive_integer, read_capacity = Contract.positive_integer,
  write_capacity = Contract.positive_integer, chunk_size = Contract.positive_integer,
  read_chunk_size = Contract.positive_integer, write_chunk_size = Contract.positive_integer,
}

local function validate_listen_options(opts)
  return IO.copy_table(Contract.record(opts, LISTEN_OPTIONS, 'socket.listen_op options', 3))
end

local function host_listener_options(opts)
  return {
    label = opts.label,
    reuse_address = opts.reuse_address,
    unlink_existing = opts.unlink_existing,
    unlink_on_close = opts.unlink_on_close,
    backlog = opts.backlog,
    nodelay = opts.nodelay,
  }
end

local function close_socket(value, reason)
  return IO.close_value('socket', value, reason)
end

function Listener:lifetime()
  return self._lifetime
end

local function local_address_now(listener)
  local state = listener._lifecycle._location.value
  return state.address or listener._address
end

function Listener:local_address_op()
  return self._lifecycle:address_op()
end


local function host_handle(listener)
  local state = listener._lifecycle._location.value
  return state.handle
end

local function accept_to_scope_op(listener, target_scope)
  return listener._offers:result_op():wrap(function(offer, source_err)
    if not offer then return nil, source_err end
    local address = local_address_now(listener)
    return Connection.from_host(
      Runtime.current(),
      target_scope,
      offer.handle,
      Connection.options(listener._options, {
        label = Label.describe(listener, listener._fibers_id) .. ':connection',
        action = 'open_accepted_stream',
        address = address,
        local_address = address,
        peer_address = offer.peer,
      })
    )
  end)
end

function Listener:accept_op(target)
  return accept_to_scope_op(self, IO.require_scope(target, 'Listener:accept_op target'))
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
  return self._lifecycle:request_stop_op(reason):wrap(function(_, state)
    if self._offers then
      local requested, request_err = perform(self._offers:close_op(reason))
      if not requested then return nil, request_err end
      local source_closed, source_err = perform(self._offers:closed_op())
      if not source_closed then return nil, source_err end
      -- Closing the offer source discharges the listener's local domain
      -- obligation.  Its Lifetime remains a child of the listener until the
      -- structural closure driver retires the ownership subtree; doing that here
      -- would compete with an enclosing close claim.
    end
    return true, state
  end)
end

function Listener:closed_op()
  local terminal = self._lifecycle:terminal_op()
  if not self._offers then return terminal:map(listener_close_result) end
  local source_closed = self._offers:closed_op()
  return source_closed:and_then(Op.guard(function(ok, source_err)
    if not ok then return Op.always(nil, source_err) end
    return terminal:map(listener_close_result)
  end))
end

local function retire_listener(listener, rt, source_state)
  local reason = source_state.reason or 'listener offer source stopped'
  local err = source_state.kind == 'failed' and source_state.error or nil
  local fatal = err ~= nil and not IOError.is(err)
  local _, state = IO.masked_perform(rt, listener._lifecycle:request_stop_op(reason, err, fatal))
  local close_error
  if state.handle and not listener._handle_closed then
    listener._handle_closed = true
    local ok, close_err = IO.safe_close('socket', state.handle, reason, {
      domain = 'socket',
      action = 'close_listener',
      address = state.address,
    })
    if not ok then
      close_error = close_err
      IO.masked_perform(rt, listener._lifecycle:record_close_error_op(close_err))
    end
  end
  IO.masked_perform(rt, listener._lifecycle:stopped_op(reason, err, fatal or close_error ~= nil))
  if close_error then return nil, close_error end
  return true
end

local function accepted_offers(listener, opts)
  return HostOffer.new({
    label = Label.describe(listener, listener._fibers_id) .. ':accepted',
    domain = 'socket',
    action = 'accept',
    role = 'socket_accept_source',
    capacity = opts.accept_capacity or 32,
    handle = function() return host_handle(listener) end,
    mode = 'read',
    pull = function(registered_handle)
      local handle, peer, accept_err = registered_handle:accept()
      if not handle then return nil, accept_err end

      return { handle = handle, peer = peer }
    end,
    dispose = function(offer, reason)
      local closed, close_err = close_socket(offer.handle, reason or 'accepted offer discarded')
      if not closed then error(close_err, 0) end
    end,
    closed_error = function(err)
      return IOError.closed('socket', 'accept', {
        reason = err and err.reason or 'listener closed',
        address = local_address_now(listener),
      })
    end,
    retired = function(rt, state)
      return retire_listener(listener, rt, state)
    end,
  })
end

function Module.listen_op(address, opts)
  address = Address.validate(address, 'socket.listen_op')
  opts = validate_listen_options(opts)
  local scope = IO.current_scope(opts, 'socket.listen_op')
  next_listener = next_listener + 1
  local id = 'listener-' .. tostring(next_listener)
  local listener = Label.attach(setmetatable({
    kind = 'socket_listener',
    _fibers_id = id,
    _address = address,
    _lifecycle = ListenerLifecycle.new(address),
    _options = opts,
  }, Listener), opts.label)
  Label.child(listener._lifecycle, listener, 'lifecycle')

  Lifetime.define(listener, {
    label = opts.label,
    role = 'socket_listener',
    closure = IO._closeable_closure(listener, {
      name = 'listener', reason = 'scope closure', finish_result = 'listener closure failed',
    }),
  })
  local private_scope = Scope.for_lifetime(listener._lifetime)
  listener._private_scope = private_scope

  return scope:admit_op(listener):wrap(function()
    local active, activation_err = Activation.create(listener, {
      host = opts.host,
      host_method = 'create_listener',
      options = host_listener_options(opts),
      lifecycle = listener._lifecycle,
      close = close_socket,
      domain = 'socket',
      action = 'listen',
      role = 'listener',
      address = address,
      closed_reason = 'listener lifecycle no longer accepts activation',
      closed_message = 'listener closed before activation',
    })
    if not active then return nil, activation_err end

    listener._offers = accepted_offers(listener, opts)
    local opened, open_err = perform(listener._offers:open_op(private_scope))
    if not opened then
      local cleanup = {}
      IOError.capture_cleanup(cleanup, 'socket', 'listener_start_cleanup', { address = address },
        retire_listener, listener, Runtime.current(), {
          kind = 'failed',
          reason = 'listener offer source failed to open',
          error = open_err,
        })
      return nil, IOError.with_cleanup(
        open_err, 'socket', 'listen',
        'listener start and cleanup both failed', cleanup, { address = address }
      )
    end
    return listener
  end)
end

function Listener:accept(target)
  target = target or IO.current_scope({}, 'Listener:accept')
  return perform(self:accept_op(target))
end



Module.Listener = Listener
Direct.install(Listener, { 'local_address', 'close', 'closed' })

return Module
