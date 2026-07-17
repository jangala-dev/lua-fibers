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

local Harness = require('tests.support.harness')
local groups = require('tests.groups')

local order = {
  'public',
  'composition',
  'resources',
  'lifetimes',
  'embedding',
  'io',
  'kernel',
  'internal',
  'case_studies',
  'experiments',
  'performance',
}

local tests = {}
for i = 1, #order do
  local group = groups[order[i]] or {}
  for j = 1, #group do
    tests[#tests + 1] = group[j]
  end
end

local opts = Harness.parse_args(arg, 'FIBERS_TEST')
opts.label = 'tests/run_all.lua'
opts.command = 'lua tests/run_all.lua'

return Harness.run(tests, opts)
