package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local test_etfcore = require('tests.test_etfcore')
test_etfcore.run_tests()
