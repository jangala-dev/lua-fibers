-- Shared construction substrate for Cell and Machine.

local Facility = require('fibers.resource.authoring')

local StateResource = {}

function StateResource.init(resource, value, algebra, semantics, label)
  if type(semantics) ~= 'table'
      or type(semantics.capture) ~= 'function'
      or type(semantics.expose) ~= 'function'
      or type(semantics.equal) ~= 'function' then
    error('state resource requires value semantics', 2)
  end

  resource._value_semantics = semantics
  value = semantics.capture(value, label or 'state value', 4)
  resource._location = Facility.location(resource, {
    algebra = algebra or 'replace',
    domain = 'plain',
    value = value,
    value_equal = semantics.equal,
  })
  return resource
end

return StateResource
