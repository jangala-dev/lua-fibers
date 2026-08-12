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
local Protected = require('fibers.protected')
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
  return IO.copy_table(Contract.record(opts, LISTEN_OPTIONS, 'socket.listen options', 3))
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

function Listener:local_address_op()
  return self._lifecycle:address_op()
end

function Listener:ready_op()
  return self._lifecycle:start_result_op():map(function(handle, err)
    if not handle then return nil, err end
    return self
  end)
end

local function accept_to_scope_op(listener, target_scope)
  return listener._offers:result_op():and_then(Op.guard(function(offer, source_err)
    if not offer then return Op.always(nil, source_err) end
    local address = Lifecycle.address(listener)
    return Connection.from_host_op(
      target_scope,
      offer.handle,
      Connection.options(listener._options, {
        label = Label.describe(listener, listener._fibers_id) .. ':connection',
        action = 'open_accepted_stream',
        address = address,
        local_address = address,
        peer_address = offer.peer,
        addresses_resolved = true,
      })
    )
  end))
end

function Listener:accept_op(target)
  return accept_to_scope_op(self, IO.require_scope(target, 'Listener:accept_op target'))
end

function Listener:request_close_op(reason)
  reason = reason or 'listener closed'
  return self._lifecycle:request_stop_op(reason):and_then(Op.guard(function(first, state)
    if not self._offers then return Op.always(true, first, state) end
    return self._offers:request_close_op(reason):map(function(requested, err)
      if not requested then return nil, err end
      return true, first, state
    end)
  end))
end

function Listener:closed_op()
  return IO.closed_after_driver_op(self._driver, self._lifecycle:terminal_op():map(Lifecycle.close_result))
end

function Listener:close(reason)
  local requested, request_err = perform(self:request_close_op(reason))
  if not requested then return nil, request_err end
  return perform(self:closed_op())
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
    handle = function() return Lifecycle.handle(listener) end,
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
        address = Lifecycle.address(listener),
      })
    end,
    retired = function(rt, state)
      return retire_listener(listener, rt, state)
    end,
  })
end

local function driver(listener, driver_scope, opts, address)
  local activated, active, activation_err = Protected.pcall(Activation.create, listener, {
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
  if not activated then
    local failure = IOError.is(active) and active or IO.protocol_error('socket', 'listen', active, { address = address })
    return nil, failure
  end
  if not active then return nil, activation_err end

  listener._offers = accepted_offers(listener, opts)
  local opened, open_err = perform(listener._offers:open_op(driver_scope))
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

  local source_closed, source_err = perform(listener._offers:closed_op())
  if not source_closed then return nil, source_err end
  local terminal = perform(listener._lifecycle:terminal_op())
  return Lifecycle.close_result(terminal)
end

function Module.submit_listen_op(address, opts)
  address = Address.validate(address, 'socket.submit_listen_op')
  opts = validate_listen_options(opts)
  local scope = IO.current_scope(opts, 'socket.submit_listen_op')
  local listener = Label.attach(Label.identity(setmetatable({
    kind = 'socket_listener',
    _address = address,
    _lifecycle = ListenerLifecycle.new(address),
    _options = opts,
  }, Listener), 'listener'), opts.label)
  Label.child(listener._lifecycle, listener, 'lifecycle')

  return scope:_drive_op(listener, {
    label = Label.get(listener),
    role = 'socket_listener',
    closure = IO._closeable_closure(listener, {
      name = 'listener', reason = 'scope closure', request = 'request_close_op',
      finish_result = 'listener closure failed',
    }),
    run = function(driver_scope) return driver(listener, driver_scope, opts, address) end,
  })
end

function Module.listen(address, opts)
  local listener, err = perform(Module.submit_listen_op(address, opts))
  if not listener then return nil, err end
  local ready, ready_err = listener:ready()
  if not ready then
    listener:closed()
    return nil, ready_err
  end
  return listener
end

function Listener:accept(target)
  target = target or IO.current_scope({}, 'Listener:accept')
  return perform(self:accept_op(target))
end



Module.Listener = Listener
Direct.install(Listener, { 'ready', 'local_address', 'request_close', 'closed' })

return Module
