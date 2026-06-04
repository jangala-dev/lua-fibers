package.path = table.concat({
  './?.lua', './?/init.lua', './?/?.lua',
  package.path,
}, ';')

local tests = {
  'tests.test_kernel',
  'tests.test_op',
  'tests.test_protocol',
  'tests.test_protocol_values',
  'tests.test_protocol_effect',
  'tests.test_protocol_link',
  'tests.test_protocol_link_laws',
  'tests.test_machine',
  'tests.test_machine_frontier',
  'tests.test_machine_proofnet',
  'tests.test_machine_world',
  'tests.test_machine_commit',
  'tests.test_runtime',
  'tests.test_runtime_engine',
  'tests.test_small_world_invariants',
  'tests.test_resources_cell',
  'tests.test_resources_channel',
  'tests.test_resources_queue',
  'tests.test_algebra_laws',
  'tests.test_algebra_canonical_fiendish',
  'tests.test_dependency_layers',
}

for i = 1, #tests do
  require(tests[i])()
end
print('all tests: ok')
