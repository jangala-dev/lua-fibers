-- Shared blocking resolver semantics for one native family.

local HostError = require('fibers.host.error')

local M = {}

local function address_key(address)
  return table.concat({
    address.kind,
    tostring(address.host),
    tostring(address.port),
    tostring(address.scope_id or 0),
  }, ':')
end

function M.define(spec)
  local Resolver = {}
  function Resolver.is_supported()
    return spec.is_supported()
  end
  function Resolver.support_reason()
    return Resolver.is_supported() and nil or spec.reason
  end
  function Resolver.resolve(_host, endpoint, opts)
    local records, err = spec.query(endpoint, opts or {})
    if not records then
      return nil, err
    end
    local out, seen = {}, {}
    for _, record in spec.records(records) do
      local address = spec.address(record, endpoint.service)
      if address then
        local key = address_key(address)
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = address
        end
      end
    end
    if #out == 0 then
      return nil,
        HostError.system(
          'resolver',
          'resolve',
          'name resolved to no usable stream addresses',
          'EAI_NONAME',
          nil,
          { endpoint = endpoint }
        )
    end
    return out
  end
  return Resolver
end

return M
