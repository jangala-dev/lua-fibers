package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local test_etfcore = require('tests.test_etfcore')
local test_algebra = require('tests.test_algebra')
local test_resources = require('tests.test_resources')
test_etfcore.run_tests()
test_algebra.run_tests()
test_resources.run_tests()
