-- Construction and ownership transfer for connected socket Streams.

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
    if source[key] ~= nil then out[key] = source[key] end
  end
  return out
end

local function require_address_accessor(handle, name)
  local accessor = handle[name]
  if type(accessor) ~= 'function' then
    error('connected host handle must provide ' .. name .. '()', 3)
  end
  return accessor(handle)
end


local function abort_with_cleanup(rt, connection, primary, action, address)
  local cleanup = {}
  IOError.capture_cleanup(cleanup, 'socket', 'connection_abort', { address = address }, function()
    return IO.masked_perform(rt, connection:abort_op(primary))
  end)
  return IOError.with_cleanup(
    primary, 'socket', action,
    'connection setup and Stream cleanup both failed', cleanup,
    { address = address }
  )
end

function Connection.from_host(rt, scope, handle, opts)
  local action = opts.action or 'open_connection'
  local connection
  local opened, open_err = Protected.pcall(function()
    connection = IO.masked_perform(rt, IO.handle_stream_op(scope, handle, {
      label = opts.label, read = true, write = true,
    }, opts))
  end)
  if not opened then
    local failure = IOError.normalise(open_err, {
      domain = 'socket',
      action = action,
      address = opts.address,
    })
    local cleanup = {}
    IOError.capture_cleanup(cleanup, 'socket', action .. '_handle_close', { address = opts.address },
      IO.close_value, 'socket', handle, failure)
    return nil, IOError.with_cleanup(
      failure, 'socket', action,
      'connection opening and handle disposal both failed', cleanup,
      { address = opts.address }
    )
  end

  local addressed, local_address, peer_address = Protected.pcall(function()
    local local_value = opts.local_address
    if local_value == nil then
      local_value = require_address_accessor(handle, 'local_address')
    end
    local peer_value = opts.peer_address
    if peer_value == nil then
      peer_value = require_address_accessor(handle, 'peer_address')
    end
    return local_value, peer_value or opts.default_peer
  end)
  if not addressed then
    local failure = IO.protocol_error('socket', action, local_address, {
      address = opts.address,
    })
    return nil, abort_with_cleanup(rt, connection, failure, action, opts.address)
  end

  connection:_set_addresses(local_address, peer_address)
  return connection
end

return Connection
