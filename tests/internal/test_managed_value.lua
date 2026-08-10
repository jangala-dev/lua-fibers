package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local ManagedValue = require('fibers.internal.managed_value')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function assert_rejected(value, needle)
  local ok, err = pcall(ManagedValue.capture, value, 'test value')
  assert_eq(ok, false, 'invalid managed value was accepted')
  if not tostring(err):find(needle, 1, true) then
    error('expected error containing ' .. needle .. ', got:\n' .. tostring(err), 2)
  end
end

local original = { name = 'radio', enabled = true, nested = { count = 3 }, [7] = 'seven' }
local captured = ManagedValue.capture(original, 'test value')
assert(captured ~= original)
assert(captured.nested ~= original.nested)
assert(ManagedValue.equal(captured, original))
original.nested.count = 99
assert_eq(captured.nested.count, 3)

local exposed = ManagedValue.expose(captured)
assert(exposed ~= captured)
assert(exposed.nested ~= captured.nested)
exposed.nested.count = 41
assert_eq(captured.nested.count, 3)
assert(ManagedValue.equal(captured, { name = 'radio', enabled = true, nested = { count = 3 }, [7] = 'seven' }))
assert(ManagedValue.equal(0 / 0, 0 / 0))

assert_rejected({ callback = function() end }, 'forbidden function value')
assert_rejected(setmetatable({ value = 1 }, {}), 'table with a metatable')

local cycle = {}
cycle.self = cycle
assert_rejected(cycle, 'contains a cycle')

local shared = { value = 1 }
assert_rejected({ a = shared, b = shared }, 'shared table reference')

local key = {}
assert_rejected({ [key] = true }, 'forbidden table key')

print('tests/internal/test_managed_value.lua: ok')
