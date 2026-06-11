package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local tests = {
  'tests/test_protected.lua',
  'tests/test_op.lua',
  'tests/test_resources.lua',
  'tests/test_runtime.lua',
  'tests/test_consequences.lua',
  'tests/test_contracts.lua',
  'tests/test_open_resources.lua',
  'tests/test_candidate.lua',
  'tests/test_solver_state.lua',
  'tests/test_residual_or_else.lua',
  'tests/test_base_kit.lua',
  'tests/test_source.lua',
  'tests/test_region_general.lua',
  'tests/test_policy.lua',
  'tests/test_lifetime.lua',
  'tests/test_invariants.lua',
}

for i = 1, #tests do
  local ok, err = pcall(dofile, tests[i])
  if not ok then error(tests[i] .. ' failed: ' .. tostring(err), 0) end
end

print('tests/run_all.lua: ok')
