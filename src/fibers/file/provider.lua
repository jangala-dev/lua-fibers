-- Runtime-owned file-provider selection.

local HostError = require('fibers.host.error')
local Worker = require('fibers.file.worker_provider')

local Provider = {}
local by_runtime = setmetatable({}, { __mode = 'k' })

function Provider.for_runtime(runtime, opts)
  if not runtime then
    error('file provider requires a current runtime', 2)
  end
  opts = opts or {}
  if opts.provider then
    return opts.provider
  end
  local cached = by_runtime[runtime]
  if cached and (type(cached.is_supported) ~= 'function' or cached:is_supported()) then
    return cached
  end
  by_runtime[runtime] = nil
  local host = runtime.host
  local provider
  if host and type(host.file_provider) == 'function' then
    local ok, value = pcall(host.file_provider, host, runtime, opts)
    if ok and value then
      provider = value
    end
  end
  provider = provider or Worker.new(runtime, opts)
  if type(provider.is_supported) == 'function' and not provider:is_supported() then
    return nil, HostError.unsupported('file', 'provider', { host = host and host.name })
  end
  by_runtime[runtime] = provider
  if type(provider.shutdown) == 'function' and type(runtime._add_finalizer) == 'function' then
    runtime:_add_finalizer(function()
      by_runtime[runtime] = nil
      return provider:shutdown()
    end)
  end
  return provider
end

return Provider
