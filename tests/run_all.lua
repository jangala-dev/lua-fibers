package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

require('fibers.diagnostics.io').install(require('fibers.diagnostics.io_observer'))

local Harness = require('tests.support.harness')
local groups = require('tests.groups')

local profiles = require('tests.profiles')
local profile_name = os.getenv('FIBERS_TEST_PROFILE') or 'default'
local order = profiles[profile_name]
if not order then
  error('unknown FIBERS_TEST_PROFILE: ' .. tostring(profile_name), 0)
end

local tests = {}
for i = 1, #order do
  local group = groups[order[i]] or {}
  for j = 1, #group do
    tests[#tests + 1] = group[j]
  end
end

local opts = Harness.parse_args(arg, 'FIBERS_TEST')
opts.label = 'tests/run_all.lua[' .. profile_name .. ']'
opts.command = 'lua tests/run_all.lua'

return Harness.run(tests, opts)
