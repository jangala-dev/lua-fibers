-- Shared optional-provider discovery and unsupported-provider scaffolding.

local Provider = {}
local Registry = {}
Registry.__index = Registry

function Provider.unsupported(prefix, reason, methods)
  local value = {
    is_supported = function()
      return false, reason
    end,
    support_reason = function()
      return reason
    end,
  }
  for i = 1, #(methods or {}) do
    local name = methods[i]
    value[name] = function()
      error(prefix .. ': ' .. tostring(reason), 2)
    end
  end
  return value
end

function Provider.registry(kind, modules)
  return setmetatable({ kind = kind, modules = modules }, Registry)
end

function Registry:module_name(name)
  local module_name = self.modules[name]
  if not module_name then
    error('unknown ' .. self.kind .. ' backend ' .. tostring(name), 3)
  end
  return module_name
end

function Registry:load(name)
  return require(self:module_name(name))
end

function Registry:new(name, opts)
  return self:load(name).new(opts)
end

function Registry:names()
  local out = {}
  for name in pairs(self.modules) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

function Registry:available()
  local out = {}
  for name, module_name in pairs(self.modules) do
    local ok, module = pcall(require, module_name)
    local supported, reason = false, 'not loadable'
    if ok and module and type(module.is_supported) == 'function' then
      supported, reason = module.is_supported()
    elseif ok then
      supported = true
    else
      reason = module
    end
    out[#out + 1] = {
      name = name,
      module = module_name,
      supported = not not supported,
      reason = reason,
    }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function Registry:first(order, opts)
  for i = 1, #order do
    local name = order[i]
    local ok, module = pcall(require, self.modules[name])
    if ok and module then
      if type(module.is_supported) ~= 'function' or module.is_supported() then
        return module.new(opts)
      end
    end
  end
end

return Provider
