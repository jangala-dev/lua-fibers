return require('fibers.host.provider.ffi_linux').load('ffi', 'luajit_linux', {
  resolver_enabled = type(rawget(_G, 'jit')) == 'table',
})
