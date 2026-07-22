-- Shared stream-socket semantics for one atomic host family.
--
-- Family adapters provide raw socket operations and address conversion.  This
-- module owns listener/dial lifecycle, handle decoration, options, readiness
-- and typed failure discipline.

local HostError = require('fibers.host.error')
local Family = require('fibers.host.family')

local M = {}

local function close_failed(handle, err)
  if handle then
    handle:close(err)
  end
  return nil, err
end

function M.define(spec)
  local Socket = {}
  local function raw_of(handle)
    return spec.raw and spec.raw(handle) or handle.handle or handle.fd or handle.obj
  end

  local function unsupported(reason)
    local value = Family.unsupported(spec.prefix, reason, { 'create_listener', 'start_dial' })
    value.supports_ipv4 = function()
      return false
    end
    value.supports_ipv6 = function()
      return false
    end
    value.supports_unix = function()
      return false
    end
    return value
  end

  if spec.unavailable then
    return unsupported(spec.unavailable)
  end

  function Socket.supports_ipv4()
    return spec.supports('inet4')
  end
  function Socket.supports_ipv6()
    return spec.supports('inet6')
  end
  function Socket.supports_unix()
    return spec.supports('unix')
  end
  function Socket.is_supported()
    return Socket.supports_ipv4() or Socket.supports_ipv6() or Socket.supports_unix()
  end
  function Socket.support_reason()
    return Socket.is_supported() and nil or spec.support_reason
  end

  local function wrap(raw, host, name, family)
    local handle, err = spec.wrap(raw, host, name)
    if not handle then
      return nil, HostError.normalise(err, { domain = 'socket', action = 'wrap' })
    end
    handle.family = spec.handle_family
    handle.socket_family = family
    handle.local_address = function(self)
      return spec.query(raw_of(self), false, family)
    end
    handle.peer_address_value = function(self)
      return spec.query(raw_of(self), true, family)
    end
    return handle
  end

  function Socket.create_listener(host, address, opts)
    opts = opts or {}
    local endpoint, address_err = spec.encode(address)
    if not endpoint then
      return nil, address_err
    end
    if not spec.supports(endpoint.family) then
      return nil, HostError.unsupported('socket', 'listen', { address = address })
    end

    local raw, open_err = spec.open(endpoint.family)
    if not raw then
      return nil, open_err
    end
    local handle, wrap_err = wrap(raw, host, opts.name or (spec.name .. '-listener'), endpoint.family)
    if not handle then
      spec.close_raw(raw)
      return nil, wrap_err
    end

    if not spec.is_unix(endpoint.family) and opts.reuse_address ~= false then
      local ok, err = spec.set_reuse(raw, true, address)
      if not ok then
        return close_failed(handle, err)
      end
    elseif spec.is_unix(endpoint.family) and opts.unlink_existing == true then
      spec.unlink(address.path)
    end

    local ok, err = spec.bind(raw, endpoint, address)
    if not ok then
      return close_failed(handle, err)
    end
    ok, err = spec.listen(raw, tonumber(opts.backlog) or 128, address)
    if not ok then
      return close_failed(handle, err)
    end

    local unix_path = spec.is_unix(endpoint.family) and address.path or nil
    if unix_path and opts.unlink_on_close ~= false then
      handle._after_close = function()
        spec.unlink(unix_path)
      end
    end
    handle.address = spec.query(raw, false, endpoint.family) or address
    handle.local_address = function(self)
      return self.address
    end
    handle.accept = function(self)
      self:clear_readable()
      local child_raw, peer, accept_err = spec.accept(raw_of(self), self.address)
      if not child_raw then
        return nil, nil, accept_err
      end
      local child, child_err =
        wrap(child_raw, host, (opts.name or 'listener') .. ':accepted', endpoint.family)
      if not child then
        spec.close_raw(child_raw)
        return nil, nil, child_err
      end
      if not spec.is_unix(endpoint.family) and opts.nodelay ~= false then
        local set, nodelay_err = spec.set_nodelay(child_raw, true, self.address)
        if not set then
          child:close(nodelay_err)
          return nil, nil, nodelay_err
        end
      end
      peer = spec.decode_peer(peer, endpoint.family) or spec.query(child_raw, true, endpoint.family)
      child.peer_address = peer
      child.local_address_value = spec.query(child_raw, false, endpoint.family)
      if spec.prime then
        spec.prime(child)
      end
      return child, peer
    end
    return handle
  end

  function Socket.start_dial(host, address, opts)
    opts = opts or {}
    local endpoint, address_err = spec.encode(address)
    if not endpoint then
      return nil, address_err
    end
    if not spec.supports(endpoint.family) then
      return nil, HostError.unsupported('socket', 'dial', { address = address })
    end

    local raw, open_err = spec.open(endpoint.family)
    if not raw then
      return nil, open_err
    end
    local handle, wrap_err = wrap(raw, host, opts.name or (spec.name .. '-dial'), endpoint.family)
    if not handle then
      spec.close_raw(raw)
      return nil, wrap_err
    end

    if opts.local_address then
      local local_endpoint, local_err = spec.encode(opts.local_address)
      if not local_endpoint then
        return close_failed(handle, local_err)
      end
      if local_endpoint.family ~= endpoint.family then
        return close_failed(
          handle,
          HostError.invalid_argument('socket', 'bind', {
            address = opts.local_address,
            message = 'local and peer address families differ',
          })
        )
      end
      local bound, bind_err = spec.bind(raw, local_endpoint, opts.local_address)
      if not bound then
        return close_failed(handle, bind_err)
      end
    end

    if not spec.is_unix(endpoint.family) and opts.nodelay ~= false then
      local ok, err = spec.set_nodelay(raw, true, address)
      if not ok then
        return close_failed(handle, err)
      end
    end

    handle.target_address = address
    local state, connect_err = spec.connect(raw, endpoint, address)
    if not state then
      return close_failed(handle, connect_err)
    end
    handle._connect_complete = state == 'connected'
    handle._connect_pending = state == 'pending'
    if handle._connect_complete and spec.prime then
      spec.prime(handle)
    end

    handle.finish_connect = function(self)
      if self._connect_complete then
        return self, spec.query(raw_of(self), true, endpoint.family) or address
      end
      self:clear_writable()
      local next_state, err = spec.finish_connect(raw_of(self), endpoint, address)
      if next_state == 'pending' then
        return nil, nil, err
      end
      if not next_state then
        return nil, nil, err
      end
      self._connect_complete, self._connect_pending = true, false
      if spec.prime then
        spec.prime(self)
      end
      return self, spec.query(raw_of(self), true, endpoint.family) or address
    end
    return handle
  end

  return Socket
end

return M
