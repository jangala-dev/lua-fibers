package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Harness = require('tests.harness')

local tests = {
  'tests/test_protected.lua',
  'tests/test_op.lua',
  'tests/test_resources.lua',
  'tests/test_runtime.lua',
  'tests/test_runtime_lifecycle.lua',
  'tests/test_effects.lua',
  'tests/test_contracts.lua',
  'tests/test_open_resources.lua',
  'tests/test_proposal.lua',
  'tests/test_residual_or_else.lua',
  'tests/test_semantic_absence.lua',
  'tests/test_absence_laws.lua',
  'tests/test_frontier_invalidation.lua',
  'tests/test_validity_algebra.lua',
  'tests/test_validity_cursor_adversarial.lua',
  'tests/test_validity_no_global_epoch.lua',
  'tests/test_local_proof_reduction.lua',
  'tests/test_base_kit.lua',
  'tests/test_source.lua',
  'tests/test_sleep.lua',
  'tests/test_host.lua',
  'tests/test_readiness.lua',
  'tests/test_host_linux.lua',
  'tests/test_host_handle.lua',
  'tests/hosts/test_all.lua',
  'tests/test_region_general.lua',
  'tests/test_policy.lua',
  'tests/test_lifetime.lua',
  'tests/test_settlement_structure.lua',
  'tests/test_flow_reservoir.lua',
  'tests/test_flow_helpers.lua',
  'tests/test_flow_settlement.lua',
  'tests/test_stream_memory.lua',
  'tests/test_stream_pumped.lua',
  'tests/test_stream_socket_backend.lua',
  'tests/test_invariants.lua',
}

local opts = Harness.parse_args(arg, 'FIBERS_TEST')
opts.label = 'tests/run_all.lua'
opts.command = 'lua tests/run_all.lua'

return Harness.run(tests, opts)
