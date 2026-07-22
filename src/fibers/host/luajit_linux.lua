local Native = require('fibers.host.native')

-- TexLua and LuaJITTeX can expose modules named `ffi` without providing the
-- LuaJIT runtime contract expected by this host.  Probe the runtime first so
-- merely requiring this optional host remains quiet and safe on those VMs.
if type(rawget(_G, 'jit')) ~= 'table' then
  return Native.define({
    name = 'luajit_linux',
    family = 'numeric-fd',
    available = false,
    reason = 'LuaJIT runtime unavailable',
  })
end

return require('fibers.host.provider.ffi_linux').load('ffi', 'luajit_linux', {
  resolver_enabled = true,
})
