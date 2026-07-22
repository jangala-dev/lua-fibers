-- Shared datagram-socket semantics for one atomic host family.

local HostError = require('fibers.host.error')
local Family = require('fibers.host.family')

local M = {}

function M.define(spec)
  if spec.unavailable then
    return Family.unsupported(spec.prefix, spec.unavailable, { 'create_datagram' })
  end

  local Provider = {}
  local function raw_of(handle)
    return spec.raw and spec.raw(handle) or handle.handle or handle.fd or handle.obj
  end
  function Provider.is_supported()
    return spec.is_supported()
  end

  function Provider.create_datagram(host, address, opts)
    opts = opts or {}
    if not Provider.is_supported() then
      return nil, HostError.unsupported('datagram', 'open', { reason = spec.support_reason })
    end
    local endpoint, address_err = spec.encode(address)
    if not endpoint then
      return nil, address_err
    end
    local raw, open_err = spec.open(endpoint.family, address)
    if not raw then
      return nil, open_err
    end

    local function fail(err)
      spec.close_raw(raw)
      return nil, err
    end
    if opts.reuse_address == true then
      local ok, err = spec.set_reuse(raw, true, address)
      if not ok then
        return fail(err)
      end
    end
    local ok, bind_err = spec.bind(raw, endpoint, address)
    if not ok then
      return fail(bind_err)
    end

    local handle, wrap_err = spec.wrap(raw, host, opts.name or (spec.name .. '-datagram'))
    if not handle then
      return fail(wrap_err)
    end
    handle.address = spec.query(raw, endpoint.family) or address
    handle.local_address = function(self)
      return self.address
    end
    handle.recv_from = function(self, max_size)
      self:clear_readable()
      return spec.receive(raw_of(self), max_size, endpoint.family, self.address)
    end
    handle.send_to = function(self, data, destination)
      self:clear_writable()
      local target, target_err = spec.encode(destination)
      if not target then
        return nil, target_err
      end
      if target.family ~= endpoint.family then
        return nil,
          HostError.protocol('datagram', 'send_to', 'source and destination address families differ', {
            source = self.address,
            destination = destination,
          })
      end
      return spec.send(raw_of(self), data, target, destination)
    end
    return handle
  end

  return Provider
end

return M
