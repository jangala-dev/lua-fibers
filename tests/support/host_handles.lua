-- In-memory HostHandle helpers for tests.

local Handle = require('fibers.host.handle')
local HostError = require('fibers.host.error')

local Helpers = {}
local next_id = 0

function Helpers.pipe_pair(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = tostring(next_id)
  local state = {
    chunks = {},
    bytes = 0,
    read_closed = false,
    write_closed = false,
  }
  local reader, writer

  local function update()
    if reader then
      if not state.read_closed and (state.bytes > 0 or state.write_closed) then
        reader:mark_readable()
      else
        reader:clear_readable()
      end
    end
    if writer then
      if state.write_closed then
        writer:clear_writable()
      else
        -- A closed peer read side is error-ready: the next authoritative write
        -- must run and report broken_pipe rather than waiting forever for a
        -- readiness level which can never become successful.
        writer:mark_writable()
      end
    end
  end

  reader = Handle.new({
    name = (opts.name or ('manual-pipe-' .. id)) .. ':read',
    key = opts.read_key or ('manual-pipe-' .. id .. ':read'),
    host = opts.host,
    capabilities = {
      read = true,
      write = false,
      shutdown_read = true,
      shutdown_write = false,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    read = function(_self, max)
      max = tonumber(max) or 4096
      if state.read_closed then
        return nil, HostError.closed('pipe', 'read')
      end
      if state.bytes == 0 then
        if state.write_closed then
          return nil, HostError.eof('pipe', 'read')
        end
        return nil, HostError.would_block('pipe', 'read')
      end
      local first = state.chunks[1]
      local n = math.min(max, #first)
      local out = string.sub(first, 1, n)
      local rest = string.sub(first, n + 1)
      state.bytes = state.bytes - n
      if rest == '' then
        table.remove(state.chunks, 1)
      else
        state.chunks[1] = rest
      end
      update()
      return out
    end,
    shutdown_read = function()
      state.read_closed = true
      state.chunks = {}
      state.bytes = 0
      update()
      return true
    end,
    close = function()
      state.read_closed = true
      state.chunks = {}
      state.bytes = 0
      update()
      return true
    end,
  })

  writer = Handle.new({
    name = (opts.name or ('manual-pipe-' .. id)) .. ':write',
    key = opts.write_key or ('manual-pipe-' .. id .. ':write'),
    host = opts.host,
    capabilities = {
      read = false,
      write = true,
      shutdown_read = false,
      shutdown_write = true,
      close = true,
      set_nonblocking = false,
      readiness = true,
    },
    write = function(_self, bytes)
      if state.write_closed then
        return nil, HostError.closed('pipe', 'write')
      end
      if state.read_closed then
        return nil,
          HostError.new('broken_pipe', {
            domain = 'pipe',
            action = 'write',
            message = 'pipe reader is closed',
          })
      end
      if bytes == '' then
        return 0
      end
      state.chunks[#state.chunks + 1] = bytes
      state.bytes = state.bytes + #bytes
      update()
      return #bytes
    end,
    shutdown_write = function()
      state.write_closed = true
      update()
      return true
    end,
    close = function()
      state.write_closed = true
      update()
      return true
    end,
  })

  update()
  return reader, writer
end

-- Pair independent read and write handles behind the ordinary HostHandle contract.
function Helpers.duplex(read_handle, write_handle, opts)
  opts = opts or {}
  if type(read_handle) ~= 'table' or type(write_handle) ~= 'table' then
    error('host handle duplex expects read and write handles', 2)
  end
  local function each(method, value)
    for _, handle in ipairs({ read_handle, write_handle }) do
      if handle and type(handle[method]) == 'function' then
        handle[method](handle, value)
      end
    end
  end
  local handle = Handle.new({
    name = opts.name,
    key = opts.key or {
      read = read_handle:readiness_key(),
      write = write_handle:readiness_key(),
    },
    host = opts.host or read_handle.host or write_handle.host,
    capabilities = {
      read = read_handle:supports('read'),
      write = write_handle:supports('write'),
      shutdown_read = read_handle:supports('shutdown_read'),
      shutdown_write = write_handle:supports('shutdown_write'),
      close = true,
      readiness = true,
    },
    read = function(_, maximum)
      return read_handle:read(maximum)
    end,
    write = function(_, bytes)
      return write_handle:write(bytes)
    end,
    shutdown_read = function(_, reason)
      return read_handle:shutdown_read(reason)
    end,
    shutdown_write = function(_, reason)
      return write_handle:shutdown_write(reason)
    end,
    ready = function(_, mode)
      return mode == 'write' and write_handle:write_ready_op() or read_handle:read_ready_op()
    end,
    bind_runtime = function(_, runtime)
      each('bind_runtime', runtime)
    end,
    attach_stream = function(_, stream)
      each('attach_stream', stream)
    end,
    close = function(_, reason)
      local ok, err = read_handle:close(reason)
      if not ok then
        return nil, err
      end
      if write_handle ~= read_handle then
        return write_handle:close(reason)
      end
      return true
    end,
  })
  handle.read_handle, handle.write_handle = read_handle, write_handle
  return handle
end

return Helpers
