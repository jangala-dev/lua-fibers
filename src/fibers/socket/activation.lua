-- Transactional installation of newly created host socket handles.

local Runtime = require('fibers.runtime')
local IOError = require('fibers.io.error')
local IO = require('fibers.io.facility')
local IOAudit = require('fibers.internal.io_audit')
local Protected = require('fibers.protected')

local Activation = {}

local function close_with_cleanup(primary, spec, handle, reason)
  local cleanup = {}
  IOError.capture_cleanup(
    cleanup, spec.domain, spec.action .. '_cleanup', { address = spec.address },
    spec.close, handle, reason
  )
  return IOError.with_cleanup(
    primary, spec.domain, spec.action,
    spec.action .. ' failed and host-handle cleanup was incomplete',
    cleanup, { address = spec.address }
  )
end

local function fail(rt, lifecycle, err, fatal)
  IO.masked_perform(rt, lifecycle:start_failed_op(err, fatal))
  return nil, err
end

function Activation.create(owner, spec)
  local rt = Runtime.current()
  local host = spec.host or (rt and rt.host)
  local create = host and host[spec.host_method]
  if type(create) ~= 'function' then
    return fail(
      rt,
      spec.lifecycle,
      IOError.unsupported('host', spec.action, { address = spec.address })
    )
  end

  local called, handle, err = Protected.pcall(create, host, spec.address, spec.options)
  if not called then
    local failure = IO.protocol_error(spec.domain, spec.action, handle, { address = spec.address })
    fail(rt, spec.lifecycle, failure, true)
    error(failure, 0)
  end
  if not handle then
    return fail(rt, spec.lifecycle, IOError.normalise(err, {
      domain = spec.domain,
      action = spec.action,
      address = spec.address,
    }))
  end

  local held, hold_err = spec.hold:hold(spec.hold_key, handle, spec.close)
  if not held then return fail(rt, spec.lifecycle, hold_err, true) end
  local address_ok, local_address = Protected.pcall(function()
    return type(handle.local_address) == 'function' and handle:local_address() or spec.address
  end)
  if not address_ok then
    local failure = IO.protocol_error(spec.domain, spec.action, local_address, { address = spec.address })
    local discarded, discard_err = spec.hold:discard(spec.hold_key, handle, failure)
    if not discarded then
      failure = IOError.protocol(spec.domain, spec.action, 'host address query and handle disposal failed', {
        address = spec.address,
        errors = { failure, discard_err },
        cause = failure,
      })
    end
    fail(rt, spec.lifecycle, failure, true)
    error(failure, 0)
  end

  IOAudit.transfer(handle, owner, { kind = 'host_handle', role = spec.role })
  local released, release_err = spec.hold:release(spec.hold_key, handle)
  if not released then
    return fail(rt, spec.lifecycle, close_with_cleanup(release_err, spec, handle, release_err), true)
  end

  local activated = IO.masked_perform(
    rt,
    spec.lifecycle:activate_op(handle, local_address or spec.address)
  )
  if not activated then
    local closed = IOError.closed(spec.domain, spec.action, {
      reason = spec.closed_message,
      address = spec.address,
    })
    return nil, close_with_cleanup(closed, spec, handle, spec.closed_reason)
  end
  return owner
end

return Activation
