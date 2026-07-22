-- Shared parent-side process stdio planning and endpoint wrapping.

local HostError = require('fibers.host.error')

local M = {}
local STREAMS = { 'stdin', 'stdout', 'stderr' }

function M.open(spec, open_pipe, close_raw)
  local stdio = { all = {} }
  local parents = {}
  for i = 1, #STREAMS do
    local which = STREAMS[i]
    local mode = spec[which] or 'inherit'
    stdio[which] = mode
    if mode == 'pipe' then
      local reader, writer, err, extra = open_pipe(which)
      if not reader then
        for j = 1, #stdio.all do
          close_raw(stdio.all[j])
        end
        return nil, nil, err, extra
      end
      stdio.all[#stdio.all + 1] = reader
      stdio.all[#stdio.all + 1] = writer
      if which == 'stdin' then
        stdio.stdin_child, parents.stdin = reader, writer
      else
        stdio[which .. '_child'], parents[which] = writer, reader
      end
    end
  end
  return stdio, parents
end

function M.close_child_ends(stdio, parents, close_raw)
  for which in pairs(parents or {}) do
    close_raw(which == 'stdin' and stdio.stdin_child or stdio[which .. '_child'])
  end
end

function M.install_child(stdio, ops)
  local opened = {}
  local function install(which, target)
    local mode = stdio[which]
    if mode == nil or mode == 'inherit' then
      return true
    end
    if which == 'stderr' and mode == 'stdout' then
      return ops.duplicate(ops.stdout, target)
    end
    local source
    if mode == 'pipe' then
      source = stdio[which .. '_child']
    elseif mode == 'null' then
      local err, extra
      source, err, extra = ops.open_null(which)
      if source == nil then
        return nil, err, extra
      end
      opened[#opened + 1] = source
    end
    if source ~= nil and not ops.same(source, target) then
      local ok, err, extra = ops.duplicate(source, target)
      if not ok then
        return nil, err, extra
      end
    end
    return true
  end
  for i = 1, #STREAMS do
    local which = STREAMS[i]
    local ok, err, extra = install(which, ops.targets[which])
    if not ok then
      return nil, err, extra
    end
  end
  for i = 1, #stdio.all do
    local value = stdio.all[i]
    if not ops.keep(value) then
      ops.close(value)
    end
  end
  for i = 1, #opened do
    local value = opened[i]
    if not ops.keep(value) then
      ops.close(value)
    end
  end
  return true
end

local function restrict(handle, which)
  if which == 'stdin' then
    handle.capabilities.read = false
    handle.capabilities.shutdown_read = false
  else
    handle.capabilities.write = false
    handle.capabilities.shutdown_write = false
  end
end

function M.wrap(opts)
  local endpoints = {}
  local parents = opts.parents or {}
  for which, raw in pairs(parents) do
    local handle, err = opts.wrap(raw, {
      host = opts.host,
      name = (opts.name or ('process-' .. tostring(opts.pid))) .. ':' .. which,
      nonblocking = opts.nonblocking ~= false,
      cloexec = opts.cloexec,
    })
    if not handle then
      for _, endpoint in pairs(endpoints) do
        endpoint:close('process endpoint wrap failed')
      end
      for other, value in pairs(parents) do
        if other ~= which and not endpoints[other] then
          opts.close_raw(value)
        end
      end
      if opts.abort then
        opts.abort()
      end
      return nil, HostError.normalise(err, { domain = 'process', action = 'wrap_' .. which })
    end
    restrict(handle, which)
    endpoints[which] = handle
  end
  return endpoints
end

return M
