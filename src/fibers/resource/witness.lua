-- Enumerable trusted transition specifications.

local Operation = require('fibers.internal.operation')
local Algebra = require('fibers.internal.kernel.algebra')

local Witness = {}

local OPTIONS = {
  location = true,
  group = true,
  demand = true,
  payload = true,
  resource = true,
  interest = true,
  absence_check = true,
  result = true,
  cursor = true,
  order = true,
  accepts_supply = true,
  supplies = true,
}

local function validate_keys(value)
  if type(value) ~= 'table' then
    error('witness options must be a table', 3)
  end
  for key in pairs(value) do
    if not OPTIONS[key] then
      error('witness options do not accept ' .. tostring(key), 3)
    end
  end
end

function Witness.spec(opts)
  validate_keys(opts)
  local cursor_factory = assert(opts.cursor, 'witness transition requires cursor')
  return Operation.transition({
    location = assert(opts.location, 'witness transition requires location'),
    group = opts.group or opts.location,
    orientation = opts.demand,
    argument = opts.payload,
    resource = opts.resource,
    interest = opts.interest,
    absence_check = opts.absence_check,
    result = opts.result or Operation.result.value,
    transition = {
      serial = false,
      enumerable = true,
      eager = false,
      total = false,
      order = opts.order or 0,
      accepts_supply = opts.accepts_supply == true,
      supplies = Algebra.normalise_supply(opts.supplies or 'none', 'witness transition supplies', 2),
      writes = true,
      cursor = function(value, argument, context)
        local source = assert(cursor_factory(value, argument or {}, context), 'witness cursor required')
        assert(
          type(source) == 'table' and type(source.next) == 'function',
          'witness cursor factory must return { next = function }'
        )
        return {
          next = function()
            local outcome = source:next()
            if outcome == nil then
              return nil
            end
            return {
              machine = true,
              writes = outcome.writes ~= false,
              value = outcome.value,
              result = outcome.result,
            }
          end,
        }
      end,
    },
  })
end

return Witness
