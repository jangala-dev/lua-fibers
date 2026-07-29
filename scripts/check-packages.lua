-- Verify that static module dependencies respect packages/catalogue.lua.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local catalogue = require('packages.catalogue')
local Ownership = require('packages.ownership')

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function list_files(root)
  local pipe = assert(io.popen('find ' .. shell_quote(root) .. " -type f -name '*.lua' -print", 'r'))
  local out = {}
  for path in pipe:lines() do out[#out + 1] = path end
  assert(pipe:close() ~= false, 'cannot enumerate ' .. root)
  table.sort(out)
  return out
end

local function read_file(path)
  local file = assert(io.open(path, 'rb'))
  local text = file:read('*a')
  file:close()
  return text
end

local function module_name(path, root)
  local relative = assert(path:match('^' .. root .. '/(.+)$'))
  return relative:gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
end

local function owner_of(name)
  return Ownership.owner_name(name)
end

local allowed = {}
for i = 1, #catalogue do
  local package = catalogue[i]
  local set = { [package.name] = true }
  for j = 1, #(package.requires or {}) do set[package.requires[j]] = true end
  allowed[package.name] = set
end

local modules = {}
for _, path in ipairs(list_files('src')) do modules[module_name(path, 'src')] = path end

local errors = {}
for source, path in pairs(modules) do
  local source_owner = assert(owner_of(source), 'unowned module ' .. source)
  local text = read_file(path)
  for dependency in text:gmatch("require%s*%(%s*['\"](fibers[^'\"]*)['\"]%s*%)") do
    local target_owner = owner_of(dependency)
    if target_owner and not allowed[source_owner][target_owner] then
      errors[#errors + 1] = string.format(
        '%s (%s) statically depends on %s (%s), but %s does not require %s',
        source,
        source_owner,
        dependency,
        target_owner,
        source_owner,
        target_owner
      )
    end
  end
end

-- The reference source tree is owned wholly by fibers-reference.
for _, path in ipairs(list_files('reference')) do
  local source = module_name(path, 'reference')
  local text = read_file(path)
  for dependency in text:gmatch("require%s*%(%s*['\"](fibers[^'\"]*)['\"]%s*%)") do
    local target_owner = owner_of(dependency) or 'fibers-reference'
    if target_owner ~= 'fibers-core' and target_owner ~= 'fibers-reference' then
      errors[#errors + 1] = source .. ' (fibers-reference) depends on disallowed package ' .. target_owner
    end
  end
end

if #errors > 0 then
  table.sort(errors)
  io.stderr:write('package dependency errors:\n')
  for i = 1, #errors do io.stderr:write('  ', errors[i], '\n') end
  os.exit(1)
end

print('packages: ok (' .. tostring(#catalogue) .. ' published package definitions)')
