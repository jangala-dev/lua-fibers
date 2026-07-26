local Posix = require('fibers.host.posix')

if type(rawget(_G, 'jit')) ~= 'table' then
  return Posix.unavailable('fibers.host.luajit_linux', 'LuaJIT runtime unavailable')
end

return require('fibers.host.ffi_linux').load('ffi', 'luajit_linux', {
  resolver_enabled = true,
})
