-- Outbound socket dials.
--
-- Numeric and Unix endpoints use this direct strategy.

local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local Acquired = require('fibers.io.internal.acquired')
local IO = require('fibers.io.facility')
local Connection = require('fibers.socket.connection')
local Clock = require('fibers.resource.clock')
local HostOffer = require('fibers.io.offer')
local perform = require('fibers.perform')
local Contract = require('fibers.internal.contract')

local Label = require('fibers.internal.label')

local Direct = { name = 'direct' }

local DIRECT_OPTIONS = {
  scope = true, host = true, label = Contract.non_empty_string,
  nodelay = Contract.boolean, local_address = true,
  connect_deadline = Contract.finite_number,
  capacity = Contract.positive_integer, read_capacity = Contract.positive_integer,
  write_capacity = Contract.positive_integer, chunk_size = Contract.positive_integer,
  read_chunk_size = Contract.positive_integer, write_chunk_size = Contract.positive_integer,
}

function Direct.normalise_options(opts)
  local out = IO.copy_table(Contract.record(opts, DIRECT_OPTIONS, 'socket.dial_op options', 3))
  if type(out.local_address) == 'table' then out.local_address = IO.copy_table(out.local_address) end
  return out
end

local function close_socket(value, reason)
  return IO.close_value('socket', value, reason)
end

local function retain_cleanup(primary, dial, cleanup_action, action, message, fn, ...)
  local errors = {}
  IOError.capture_cleanup(errors, 'socket', cleanup_action, { address = dial._endpoint }, fn, ...)
  return IOError.with_cleanup(primary, 'socket', action, message, errors, { address = dial._endpoint })
end

local function timeout_error(dial, deadline)
  return IOError.system('socket', 'connect', 'connection attempt deadline expired', 'ETIMEDOUT', nil, {
    address = dial._endpoint,
    deadline = deadline,
  })
end

local function connect_completion(dial, handle, driver_scope)
  local source = HostOffer.new({
    label = Label.describe(dial, dial._fibers_id) .. ':completion',
    domain = 'socket',
    action = 'connect_finish',
    role = 'socket_connect_completion',
    one_shot = true,
    handle = handle,
    mode = 'write',
    pull = function(registered_handle)
      if type(registered_handle.finish_connect) ~= 'function' then
        return { peer = dial._endpoint }
      end
      local connected, peer, err = registered_handle:finish_connect()
      if connected then
        if connected ~= registered_handle then
          local failure = IOError.protocol(
            'socket',
            'connect_finish',
            'finish_connect must return the original host handle',
            { address = dial._endpoint }
          )
          return nil,
            retain_cleanup(
              failure,
              dial,
              'replacement_handle_close',
              'connect_finish',
              'finish_connect returned a replacement handle and cleanup was incomplete',
              close_socket,
              connected,
              failure
            )
        end
        return { peer = peer }
      end
      if IOError.is_would_block(err) then return nil, err end
      return nil,
        IOError.normalise(err, {
          domain = 'socket',
          action = 'connect_finish',
          address = dial._endpoint,
        })
    end,
  })
  perform(source:open_op(driver_scope))
  return source
end

local function await_connect(dial, source, deadline)
  local completed = source:result_op()
  if deadline == nil then return perform(completed) end

  local selected, err = perform(completed:or_else(Clock.default():at_op(deadline):map(function()
    return false
  end)))
  if selected == false then
    local timeout = timeout_error(dial, deadline)
    perform(source:close_op(timeout))
    local closed, close_err = perform(source:closed_op())
    if not closed then return nil, close_err end
    return nil, timeout
  end
  return selected, err
end

function Direct.terminal_report(dial, status, err, completed_at)
  local started_at = dial.started_at or completed_at
  return {
    kind = 'dial',
    strategy = 'direct',
    status = status,
    endpoint = dial._endpoint,
    started_at = started_at,
    completed_at = completed_at,
    duration = completed_at - started_at,
    error = err,
  }
end

function Direct.run(dial, driver_scope, opts)
  return Acquired.run(function(acquired)
    local rt = Runtime.current()
    local started_at = rt:now()
    dial.started_at = started_at

    local host = opts.host or rt.host
    local start_dial = host and host.start_dial
    if type(start_dial) ~= 'function' then
      local err = IOError.unsupported('host', 'dial', { address = dial._endpoint })
      return nil, err, Direct.terminal_report(dial, 'failed', err, rt:now())
    end

    local handle, err = start_dial(host, dial._endpoint, {
      label = opts.label,
      nodelay = opts.nodelay,
      local_address = opts.local_address,
    })
    if not handle then
      err = IOError.normalise(err, {
        domain = 'socket', action = 'dial', address = dial._endpoint,
      })
      return nil, err, Direct.terminal_report(dial, 'failed', err, rt:now())
    end
    acquired:hold('socket', handle, close_socket)

    local completion = connect_completion(dial, handle, driver_scope)
    local completed, finish_err = await_connect(dial, completion, opts.connect_deadline)
    if not completed then
      local cleanup = {}
      IOError.capture_cleanup(cleanup, 'socket', 'dial_handle_close', { address = dial._endpoint },
        acquired.close, acquired, finish_err)
      finish_err = IOError.with_cleanup(
        finish_err, 'socket', 'dial',
        'connection attempt failed and host-handle cleanup was incomplete', cleanup,
        { address = dial._endpoint }
      )
      return nil, finish_err, Direct.terminal_report(dial, 'failed', finish_err, rt:now())
    end

    acquired:release('socket', handle)
    local connection_opts = Connection.options(opts, {
      label = Label.describe(dial, dial._fibers_id) .. ':connection',
      action = 'open_connection',
      address = dial._endpoint,
      peer_address = completed.peer,
      default_peer = dial._endpoint,
    })
    local connection, connection_err = Connection.from_host(rt, driver_scope, handle, connection_opts)
    if not connection then error(connection_err, 0) end

    return connection, nil, Direct.terminal_report(dial, 'connected', nil, rt:now())
  end)
end

return Direct
