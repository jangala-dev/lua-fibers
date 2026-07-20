-- Host fd backend registry.
--
-- This module intentionally does not auto-select an implementation.  Select a
-- complete host family through fibers.host.* for ordinary use, or select a
-- concrete fd backend here for low-level tests and advanced code.

local Fd = {}
local Provider = require('fibers.host.provider')

local providers = Provider.registry('fd', {
  luajit = 'fibers.host.fd_luajit',
  cffi = 'fibers.host.fd_cffi',
  luaposix = 'fibers.host.fd_luaposix',
  nixio = 'fibers.host.fd_nixio',
})

function Fd.select(name)
  return providers:load(name)
end

function Fd.available()
  return providers:available()
end

function Fd.names()
  return providers:names()
end

return Fd
