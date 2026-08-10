-- Value semantics for state-backed resources.
--
-- Public Cell and Machine resources always use MANAGED: authoritative state is
-- captured on ingress, exposed as an independent value on egress, and compared
-- structurally. TRUSTED is an internal implementation privilege for facilities
-- whose private representation contains identity-bearing values. Such facilities
-- are responsible for preserving the same observable state/rollback laws.

local ManagedValue = require('fibers.internal.managed_value')

local ValueSemantics = {}

local function identity(value)
  return value
end

local function identity_equal(left, right)
  return left == right
end

ValueSemantics.managed = {
  capture = ManagedValue.capture,
  expose = ManagedValue.expose,
  equal = ManagedValue.equal,
}

ValueSemantics.trusted = {
  capture = identity,
  expose = identity,
  equal = identity_equal,
}

return ValueSemantics
