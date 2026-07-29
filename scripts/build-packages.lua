-- Emit the coarse published package source trees from packages/catalogue.lua.
-- Exact application minimisation remains the responsibility of build-profile.lua.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local catalogue = require('packages.catalogue')
local Ownership = require('packages.ownership')

local function fail(message) error(message, 0) end
local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local function command_ok(command)
  local a, _, c = os.execute(command)
  return a == true or a == 0 or c == 0
end
local function mkdir(path)
  if path ~= '' and not command_ok('mkdir -p ' .. quote(path)) then fail('cannot create ' .. path) end
end
local function dirname(path) return path:match('^(.*)/[^/]+$') or '' end
local function read(path)
  local f, err = io.open(path, 'rb'); if not f then fail(err or ('cannot read ' .. path)) end
  local text = f:read('*a'); f:close(); return text
end
local function write(path, text)
  mkdir(dirname(path)); local f, err = io.open(path, 'wb'); if not f then fail(err or ('cannot write ' .. path)) end
  f:write(text); f:close()
end
local function files(root)
  local pipe = assert(io.popen('find ' .. quote(root) .. " -type f -name '*.lua' -print", 'r'))
  local out = {}; for path in pipe:lines() do out[#out + 1] = path end
  if pipe:close() == false then fail('cannot enumerate ' .. root) end
  table.sort(out); return out
end
local function module_name(path, root)
  local relative = assert(path:match('^' .. root .. '/(.+)$'))
  return relative:gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
end
local function owner_of(name)
  return Ownership.owner(name) or fail('unowned module ' .. name)
end

local function serialise_array(values)
  local out = {}
  for i = 1, #(values or {}) do out[#out + 1] = string.format('%q', values[i]) end
  return '{ ' .. table.concat(out, ', ') .. ' }'
end
local function manifest(package, modules)
  table.sort(modules)
  return table.concat({
    '-- Generated package manifest.\n',
    'return {\n',
    '  name = ', string.format('%q', package.name), ',\n',
    '  description = ', string.format('%q', package.description or ''), ',\n',
    '  requires = ', serialise_array(package.requires), ',\n',
    '  modules = ', serialise_array(modules), ',\n',
    '}\n',
  })
end

local output = 'build/packages'
for i = 1, #arg do
  if arg[i] == '--output' then output = arg[i + 1] or fail('--output requires a value') end
end
mkdir(output)

local package_modules = {}
for _, path in ipairs(files('src')) do
  local name = module_name(path, 'src')
  local package = owner_of(name)
  local relative = assert(path:match('^src/(.+)$'))
  write(output .. '/' .. package.name .. '/src/' .. relative, read(path))
  local list = package_modules[package.name] or {}
  package_modules[package.name] = list
  list[#list + 1] = name
end

for i = 1, #catalogue do
  local package = catalogue[i]
  if package.source_root then
    local list = {}
    for _, path in ipairs(files(package.source_root)) do
      local relative = assert(path:match('^' .. package.source_root .. '/(.+)$'))
      write(output .. '/' .. package.name .. '/' .. package.source_root .. '/' .. relative, read(path))
      list[#list + 1] = module_name(path, package.source_root)
    end
    package_modules[package.name] = list
  elseif package.virtual then
    package_modules[package.name] = {}
  end
  write(output .. '/' .. package.name .. '/PACKAGE.lua', manifest(package, package_modules[package.name] or {}))
end

for i = 1, #catalogue do
  local package = catalogue[i]
  io.write(string.format('%-24s %4d modules\n', package.name, #(package_modules[package.name] or {})))
end
