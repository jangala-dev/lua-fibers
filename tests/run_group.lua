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

local name = arg and arg[1]
local tests = name and groups[name]
if not tests then
  error('usage: lua tests/run_group.lua <group>', 0)
end

table.remove(arg, 1)
local opts = Harness.parse_args(arg, 'FIBERS_TEST')
opts.label = 'tests/' .. name
opts.command = 'lua tests/run_group.lua ' .. name
return Harness.run(tests, opts)
