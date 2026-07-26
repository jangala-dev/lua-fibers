return require('fibers.host.ffi_linux').load('cffi', 'cffi_linux', {
  resolver_enabled = true,
})
