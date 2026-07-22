return require('fibers.host.ffi_family').load('ffi', 'luajit_linux', {
  -- Compatibility ffi modules may not safely traverse getaddrinfo lists.
  resolver_enabled = type(rawget(_G, 'jit')) == 'table',
})
