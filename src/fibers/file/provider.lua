-- Runtime-owned file service supplied by the selected host family.

local HostError = require('fibers.host.error')

local Provider = {}
local by_runtime = setmetatable({}, { __mode = 'k' })

function Provider.for_runtime(runtime, opts)
  if not runtime then
    error('file provider requires a current runtime', 2)
  end
  local cached = by_runtime[runtime]
  if cached and (type(cached.is_supported) ~= 'function' or cached:is_supported()) then
    return cached
  end
  by_runtime[runtime] = nil

  local host = runtime.host
  if not host or type(host.file_provider) ~= 'function' then
    return nil, HostError.unsupported('file', 'provider', { host = host and host.name })
  end
  local ok, provider = pcall(host.file_provider, host, runtime, opts or {})
  if
    not ok
    or not provider
    or (type(provider.is_supported) == 'function' and not provider:is_supported())
  then
    return nil, HostError.unsupported('file', 'provider', { host = host.name })
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
