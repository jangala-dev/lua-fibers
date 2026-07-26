-- Construction and held-host-handle transfer for connected socket Streams.

local HostError = require('fibers.host.error')
local IO = require('fibers.host.io')
local Protected = require('fibers.internal.protected')

local Connection = {}

local function address_from(handle, method_name, field_name)
  if type(handle[method_name]) == 'function' then
    return handle[method_name](handle)
  end
  return handle[field_name]
end

local function set_addresses(connection, local_address, peer_address)
  if type(connection._set_addresses) == 'function' then
    connection:_set_addresses(local_address, peer_address)
  else
    connection._local_address = local_address
    connection._peer_address = peer_address
  end
end

function Connection.open(rt, scope, handle, opts)
  return IO.open_handle_stream(rt, scope, handle, {
    name = opts.name,
    read = true,
    write = true,
    capacity = opts.capacity,
    read_capacity = opts.read_capacity,
    write_capacity = opts.write_capacity,
    chunk_size = opts.chunk_size,
    read_chunk_size = opts.read_chunk_size,
    write_chunk_size = opts.write_chunk_size,
  })
end

function Connection.from_host_hold(rt, scope, host_hold, key, handle, opts)
  local connection
  local opened, open_err = Protected.pcall(function()
    connection = Connection.open(rt, scope, handle, opts)
  end)
  if not opened then
    host_hold:close(open_err)
    return nil,
      HostError.normalise(open_err, {
        domain = 'socket',
        action = opts.action or 'open_connection',
        address = opts.address,
      })
  end

  local local_address = opts.local_address
  if local_address == nil then
    local_address = address_from(handle, 'local_address', 'local_address_value')
  end
  local peer_address = opts.peer_address
  if peer_address == nil then
    peer_address = address_from(handle, 'peer_address_value', 'peer_address_value')
  end
  peer_address = peer_address or opts.default_peer
  set_addresses(connection, local_address, peer_address)

  local released, release_err = host_hold:release(key, handle)
  if not released then
    IO.masked_perform(rt, connection:abort_op(release_err))
    return nil, release_err
  end
  return connection
end

return Connection
