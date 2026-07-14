-- Host fd backend registry.
--
-- This module intentionally does not auto-select an implementation.  Select a
-- complete host family through fibers.host.* for ordinary use, or select a
-- concrete fd backend here for low-level tests and advanced code.

local Fd = {}

local names = {
  luajit = 'fibers.host.fd_luajit',
  cffi = 'fibers.host.fd_cffi',
  luaposix = 'fibers.host.fd_luaposix',
  nixio = 'fibers.host.fd_nixio',
}

function Fd.select(name)
  local modname = names[name]
  if not modname then
    error('unknown fd backend ' .. tostring(name), 2)
  end
  return require(modname)
end

function Fd.available()
  local out = {}
  for name, modname in pairs(names) do
    local ok, mod = pcall(require, modname)
    local supported, reason = false, 'not loadable'
    if ok and mod and type(mod.is_supported) == 'function' then
      supported, reason = mod.is_supported()
    elseif ok then
      supported = true
    else
      reason = mod
    end
    out[#out + 1] = { name = name, module = modname, supported = not not supported, reason = reason }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function Fd.names()
  local out = {}
  for name in pairs(names) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

return Fd
