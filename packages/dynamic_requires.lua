-- Optional modules loaded deliberately at runtime. Exact-closure builds include
-- them only when selected by a deployment profile.

return {
  ['fibers.runtime'] = {
    optional = {
      'fibers.diagnostics.search',
      'fibers.diagnostics.io',
      'fibers.io.readiness',
    },
  },
  ['fibers.io.auto'] = {
    implementations = {
      'fibers.embed.pure',
      'fibers.io.luajit_linux',
      'fibers.io.cffi_linux',
      'fibers.io.luaposix',
      'fibers.io.nixio',
    },
  },
}
