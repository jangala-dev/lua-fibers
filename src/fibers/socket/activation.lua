-- Transactional installation of newly created host socket handles.

local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
local IOAudit = require('fibers.internal.io_audit')
local Protected = require('fibers.protected')

local Activation = {}

local function fail(rt, lifecycle, err, fatal)
  IO.masked_perform(rt, lifecycle:start_failed_op(err, fatal == true))
  return nil, err
end

function Activation.create(owner, spec)
  local rt = Runtime.current()
  local host = spec.host or (rt and rt.host)
  local create = host and host[spec.host_method]
  if type(create) ~= 'function' then
    return fail(rt, spec.lifecycle, IOError.unsupported('host', spec.action, { address = spec.address }))
  end

  local called, handle, err = Protected.pcall(create, host, spec.address, spec.options)
  if not called then
    local failure = IO.protocol_error(spec.domain, spec.action, handle, { address = spec.address })
    fail(rt, spec.lifecycle, failure, true)
    error(failure, 0)
  end
  if not handle then
    return fail(
      rt,
      spec.lifecycle,
      IOError.normalise(err, {
        domain = spec.domain,
        action = spec.action,
        address = spec.address,
      })
    )
  end

  local held, hold_err = spec.hold:hold(spec.hold_key, handle, spec.close)
  if not held then
    return fail(rt, spec.lifecycle, hold_err, true)
  end
  if type(handle.bind_runtime) == 'function' then
    handle:bind_runtime(rt)
  end

  local local_address = type(handle.local_address) == 'function' and handle:local_address() or spec.address
  IOAudit.transfer(handle, owner, { kind = 'host_handle', role = spec.role })
  local released, release_err = spec.hold:release(spec.hold_key, handle)
  if not released then
    spec.close(handle, release_err)
    return fail(rt, spec.lifecycle, release_err, true)
  end

  local activated = IO.masked_perform(rt, spec.lifecycle:activate_op(handle, local_address or spec.address))
  if not activated then
    spec.close(handle, spec.closed_reason)
    return nil,
      IOError.closed(spec.domain, spec.action, {
        reason = spec.closed_message,
        address = spec.address,
      })
  end
  return owner
end

return Activation
