return require('fibers.io.ffi_linux').load('cffi', 'cffi_linux', {
  resolver_enabled = true,
})
