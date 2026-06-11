-- Resource contract test suite.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local tests = {
  'tests/resources/test_cell.lua',
  'tests/resources/test_event.lua',
}

for i = 1, #tests do
  local ok, err = pcall(dofile, tests[i])
  if not ok then error(tests[i] .. ' failed: ' .. tostring(err), 0) end
end

print('tests/test_resources.lua: ok')
