-- Construction and held-host-handle transfer for connected socket Streams.

local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
local Protected = require('fibers.protected')

local Connection = {}


local OPTION_KEYS = {
  'nodelay',
  'capacity',
  'read_capacity',
  'write_capacity',
  'chunk_size',
  'read_chunk_size',
  'write_chunk_size',
}

function Connection.options(source, fields)
  local out = IO.copy_table(fields)
  for _, key in ipairs(OPTION_KEYS) do
    if source and source[key] ~= nil then out[key] = source[key] end
  end
  return out
end

local function require_address_accessor(handle, name)
  local accessor = handle and handle[name]
  if type(accessor) ~= 'function' then
    error('connected host handle must provide ' .. name .. '()', 3)
  end
  return accessor(handle)
end


function Connection.open(rt, scope, handle, opts)
  return IO.open_handle_stream(rt, scope, handle, {
    label = opts.label,
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
    local failure = IOError.normalise(open_err, {
      domain = 'socket',
      action = opts.action or 'open_connection',
      address = opts.address,
    })
    local discarded, discard_err = host_hold:discard(key, handle, failure)
    if not discarded then
      return nil, IOError.protocol('socket', opts.action or 'open_connection', 'connection opening and handle disposal failed', {
        address = opts.address,
        errors = { failure, discard_err },
        cause = failure,
      })
    end
    return nil, failure
  end

  local local_address = opts.local_address
  if local_address == nil then
    local_address = require_address_accessor(handle, 'local_address')
  end
  local peer_address = opts.peer_address
  if peer_address == nil then
    peer_address = require_address_accessor(handle, 'peer_address')
  end
  if peer_address == nil then peer_address = opts.default_peer end
  connection:_set_addresses(local_address, peer_address)

  local released, release_err = host_hold:release(key, handle)
  if not released then
    IO.masked_perform(rt, connection:abort_op(release_err))
    return nil, release_err
  end
  return connection
end

return Connection
