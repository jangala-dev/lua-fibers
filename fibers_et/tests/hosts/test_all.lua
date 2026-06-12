package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local Harness = require('tests.harness')

local tests = {
  { name = 'host:pure', path = 'tests/hosts/test_pure.lua' },
  { name = 'host:nixio_linux', path = 'tests/hosts/test_nixio_linux.lua' },
  { name = 'host:luaposix', path = 'tests/hosts/test_luaposix.lua' },
  { name = 'host:luajit_linux', path = 'tests/hosts/test_luajit_linux.lua' },
  { name = 'host:cffi_linux', path = 'tests/hosts/test_cffi_linux.lua' },
}

local opts = Harness.parse_args(arg, 'FIBERS_HOST_TEST')
opts.label = 'tests/hosts/test_all.lua'
opts.command = 'lua tests/hosts/test_all.lua'

return Harness.run(tests, opts)
