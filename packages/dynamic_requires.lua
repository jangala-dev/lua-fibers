-- Deliberate runtime-selected dependencies. Exact-closure builds do not include
-- these automatically; profiles must select the desired implementation.

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
