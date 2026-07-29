local Posix = require('fibers.io.posix')

if type(rawget(_G, 'jit')) ~= 'table' then
  return Posix.unavailable('fibers.io.luajit_linux', 'LuaJIT runtime unavailable')
end

return require('fibers.io.ffi_linux').load('ffi', 'luajit_linux', {
  resolver_enabled = true,
})
