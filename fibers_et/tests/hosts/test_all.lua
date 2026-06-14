package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local Harness = require('tests.harness')

local tests = {
  { name = 'host:pure', path = 'tests/hosts/test_pure.lua' },
  { name = 'host:nixio', path = 'tests/hosts/test_nixio.lua' },
  { name = 'host:luaposix', path = 'tests/hosts/test_luaposix.lua' },
  { name = 'host:luajit_linux', path = 'tests/hosts/test_luajit_linux.lua' },
  { name = 'host:fd_luajit', path = 'tests/hosts/test_fd_luajit.lua' },
  { name = 'host:cffi_linux', path = 'tests/hosts/test_cffi_linux.lua' },
  { name = 'host:fd_cffi', path = 'tests/hosts/test_fd_cffi.lua' },
  { name = 'host:fd_luaposix', path = 'tests/hosts/test_fd_luaposix.lua' },
  { name = 'host:fd_nixio', path = 'tests/hosts/test_fd_nixio.lua' },
}

local opts = Harness.parse_args(arg, 'FIBERS_HOST_TEST')
opts.label = 'tests/hosts/test_all.lua'
opts.command = 'lua tests/hosts/test_all.lua'

return Harness.run(tests, opts)
