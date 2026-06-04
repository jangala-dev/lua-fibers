package.path = table.concat({
  './?.lua', './?/init.lua', './?/?.lua',
  package.path,
}, ';')

require('tests.test_frontier')()
require('tests.test_ms4')()
require('tests.test_ms5')()
require('tests.test_ms6')()
require('tests.test_algebra_principled')()
require('tests.test_ms65_clean')()
require('tests.test_ms7')()
require('tests.test_link_custom_resources')()
require('tests.test_protocol_link')()
require('tests.test_ms8')()
require('tests.test_ms9')()
require('tests.test_resources_effective')()
require('tests.test_regression_algebra')()
require('tests.test_expansion_memo')()
require('tests.test_dependency_layers')()
print('all tests: ok')
