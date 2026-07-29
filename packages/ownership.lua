-- Deterministic module ownership for published Fibers packages.
--
-- Exact module declarations always take precedence over prefixes. Prefixes are
-- matched longest-first, so catalogue order cannot silently change ownership.

local catalogue = require('packages.catalogue')

local Ownership = {}
local by_name = {}
local exact = {}
local prefixes = {}
local fallback

local function fail(message)
  error('package catalogue: ' .. message, 2)
end

for i = 1, #catalogue do
  local package = catalogue[i]
  if type(package.name) ~= 'string' or package.name == '' then
    fail('package ' .. tostring(i) .. ' has no name')
  end
  if by_name[package.name] then
    fail('duplicate package name ' .. package.name)
  end
  by_name[package.name] = package
  if package.fallback then
    if fallback then fail('multiple fallback packages: ' .. fallback.name .. ' and ' .. package.name) end
    fallback = package
  end
  if not package.virtual and not package.source_root then
    for j = 1, #(package.modules or {}) do
      local module = package.modules[j]
      if exact[module] then
        fail('module ' .. module .. ' is owned by both ' .. exact[module].name .. ' and ' .. package.name)
      end
      exact[module] = package
    end
    for j = 1, #(package.prefixes or {}) do
      prefixes[#prefixes + 1] = { prefix = package.prefixes[j], package = package }
    end
  end
end

for i = 1, #catalogue do
  local package = catalogue[i]
  for j = 1, #(package.requires or {}) do
    if not by_name[package.requires[j]] then
      fail(package.name .. ' requires unknown package ' .. tostring(package.requires[j]))
    end
  end
end

table.sort(prefixes, function(a, b)
  if #a.prefix ~= #b.prefix then return #a.prefix > #b.prefix end
  if a.prefix ~= b.prefix then return a.prefix < b.prefix end
  return a.package.name < b.package.name
end)
for i = 2, #prefixes do
  local a, b = prefixes[i - 1], prefixes[i]
  if a.prefix == b.prefix and a.package ~= b.package then
    fail('prefix ' .. a.prefix .. ' is owned by both ' .. a.package.name .. ' and ' .. b.package.name)
  end
end

local visiting, visited = {}, {}
local function visit(package)
  if visited[package.name] then return end
  if visiting[package.name] then fail('package dependency cycle through ' .. package.name) end
  visiting[package.name] = true
  for i = 1, #(package.requires or {}) do visit(by_name[package.requires[i]]) end
  visiting[package.name] = nil
  visited[package.name] = true
end
for i = 1, #catalogue do visit(catalogue[i]) end

function Ownership.owner(module_name)
  local package = exact[module_name]
  if package then return package end
  for i = 1, #prefixes do
    local row = prefixes[i]
    local prefix = row.prefix
    if module_name == prefix or module_name:sub(1, #prefix + 1) == prefix .. '.' then
      return row.package
    end
  end
  return fallback
end

function Ownership.owner_name(module_name)
  local package = Ownership.owner(module_name)
  return package and package.name or nil
end

function Ownership.package(name)
  return by_name[name]
end

function Ownership.catalogue()
  return catalogue
end

return Ownership
