---Optional native I/O backend discovery.
---
---Core, embedded and constrained builds should select their execution host and I/O
---provider explicitly. This module is the only first-party path which probes
---several optional native I/O packages. If none is available, `default` returns
---the portable time-only host from `fibers.embed.pure`.

local Auto = {}

local BACKEND_MODULES = {
  luajit_linux = 'fibers.io.luajit_linux',
  cffi_linux = 'fibers.io.cffi_linux',
  luaposix = 'fibers.io.luaposix',
  nixio = 'fibers.io.nixio',
}

local DEFAULT_ORDER = { 'luajit_linux', 'cffi_linux', 'luaposix', 'nixio' }

local function load_backend(name)
  local module_name = BACKEND_MODULES[name]
  if not module_name then error('unknown I/O backend ' .. tostring(name), 3) end
  return require(module_name)
end

for name in pairs(BACKEND_MODULES) do
  local selected_name = name
  Auto[selected_name] = function(opts)
    return load_backend(selected_name).new(opts)
  end
end

function Auto.select(name, opts)
  return load_backend(name).new(opts)
end

function Auto.available()
  local out = {}
  for name, module_name in pairs(BACKEND_MODULES) do
    local ok, module = pcall(require, module_name)
    local supported, reason = false, ok and nil or module
    if ok and module then
      if type(module.is_supported) == 'function' then
        supported, reason = module.is_supported()
      else
        supported = true
      end
    end
    out[#out + 1] = {
      name = name,
      module = module_name,
      supported = not not supported,
      reason = reason,
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function Auto.default(opts)
  for i = 1, #DEFAULT_ORDER do
    local ok, module = pcall(load_backend, DEFAULT_ORDER[i])
    if ok and module and (type(module.is_supported) ~= 'function' or module.is_supported()) then
      return module.new(opts)
    end
  end
  return require('fibers.embed.pure').new(opts)
end

return Auto
