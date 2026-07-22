return require('fibers.host.ffi_family').load('cffi', 'cffi_linux', {
  resolver_enabled = true,
})
