package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Harness = require('tests.harness')

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
  'tests/test_sleep.lua',
  'tests/test_host.lua',
  'tests/test_host_linux.lua',
  'tests/hosts/test_all.lua',
  'tests/test_region_general.lua',
  'tests/test_policy.lua',
  'tests/test_lifetime.lua',
  'tests/test_stream_memory.lua',
  'tests/test_invariants.lua',
}

local opts = Harness.parse_args(arg, 'FIBERS_TEST')
opts.label = 'tests/run_all.lua'
opts.command = 'lua tests/run_all.lua'

return Harness.run(tests, opts)
