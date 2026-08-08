-- Outbound socket dials.
--
-- Numeric and Unix endpoints use this direct strategy.

local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local HostHold = require('fibers.io.internal.host_hold')
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
        return { handle = registered_handle, peer = dial._endpoint }
      end
      local connected, peer, err = registered_handle:finish_connect()
      if connected then return { handle = connected, peer = peer } end
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

local function report(dial, status, started_at, completed_at, err)
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
  local rt = Runtime.current()
  local started_at = rt:now()
  dial.started_at = started_at
  local host_hold = HostHold.new():label(Label.describe(dial, dial._fibers_id) .. ':host-hold')
  perform(driver_scope:admit_op(host_hold))

  local host = opts.host or rt.host
  local start_dial = host and host.start_dial
  if type(start_dial) ~= 'function' then
    local err = IOError.unsupported('host', 'dial', { address = dial._endpoint })
    return nil, err, report(dial, 'failed', started_at, rt:now(), err)
  end

  local handle, err = start_dial(host, dial._endpoint, {
    label = opts.label,
    nodelay = opts.nodelay,
    local_address = opts.local_address,
  })
  if not handle then
    err = IOError.normalise(err, {
      domain = 'socket',
      action = 'dial',
      address = dial._endpoint,
    })
    return nil, err, report(dial, 'failed', started_at, rt:now(), err)
  end

  local held, hold_err = host_hold:hold('socket', handle, close_socket)
  if not held then error(hold_err, 0) end
  if type(handle.bind_runtime) == 'function' then handle:bind_runtime(rt) end

  local completion = connect_completion(dial, handle, driver_scope)
  local completed, finish_err = await_connect(dial, completion, opts.connect_deadline)
  if not completed then
    host_hold:close(finish_err)
    return nil, finish_err, report(dial, 'failed', started_at, rt:now(), finish_err)
  end
  local peer
  handle, peer = completed.handle, completed.peer

  local connection_opts = Connection.options(opts, {
    label = require('fibers.internal.label').describe(dial, dial._fibers_id or 'dial') .. ':connection',
    action = 'open_connection',
    address = dial._endpoint,
    peer_address = peer,
    default_peer = dial._endpoint,
  })

  local connection, connection_err =
    Connection.from_host_hold(rt, driver_scope, host_hold, 'socket', handle, connection_opts)
  if not connection then error(connection_err, 0) end

  return connection, nil, report(dial, 'connected', started_at, rt:now())
end

return Direct
