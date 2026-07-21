-- Reference evaluator loading must be opt-in and must not burden trail users.
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local function fail(msg)
  error(msg, 2)
end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

package.loaded['fibers.internal.reference_machine'] = nil
package.loaded['fibers.runtime'] = nil

local Runtime = require('fibers.runtime')
eq(
  package.loaded['fibers.internal.reference_machine'],
  nil,
  'requiring Runtime must not load the reference evaluator'
)

local ledger = Runtime.new({ machine = 'ledger' })
eq(ledger.machine_name, 'ledger')
eq(
  package.loaded['fibers.internal.reference_machine'],
  nil,
  'constructing a trail runtime must not load the reference evaluator'
)

local reference = Runtime.new({ machine = 'reference' })
eq(reference.machine_name, 'reference')
if package.loaded['fibers.internal.reference_machine'] == nil then
  fail('constructing a reference runtime must load the reference evaluator')
end

print('tests/test_reference_lazy.lua: ok')
