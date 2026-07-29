-- Resolve and emit the exact static module closure for a Fibers application.
--
-- Examples:
--   lua scripts/build-profile.lua --profile io-nixio --output build/nixio
--   lua scripts/build-profile.lua --entry fibers --entry fibers.channel --output build/app
--   lua scripts/build-profile.lua --profile core-minimal --bundle build/fibers.lua

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local profiles = require('packages.profiles')
local catalogue = require('packages.catalogue')
local Ownership = require('packages.ownership')
local dynamic_requirements = require('packages.dynamic_requires')

local function fail(message)
  error(message, 0)
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_ok(command)
  local a, _, c = os.execute(command)
  return a == true or a == 0 or c == 0
end

local function mkdir(path)
  if path and path ~= '' and not command_ok('mkdir -p ' .. shell_quote(path)) then
    fail('cannot create directory ' .. path)
  end
end

local function dirname(path)
  return path:match('^(.*)/[^/]+$') or ''
end

local function read_file(path)
  local file, err = io.open(path, 'rb')
  if not file then fail(err or ('cannot read ' .. path)) end
  local text = file:read('*a')
  file:close()
  return text
end

local function write_file(path, text)
  mkdir(dirname(path))
  local file, err = io.open(path, 'wb')
  if not file then fail(err or ('cannot write ' .. path)) end
  file:write(text)
  file:close()
end

local function list_files(root)
  local pipe = assert(io.popen('find ' .. shell_quote(root) .. " -type f -name '*.lua' -print", 'r'))
  local out = {}
  for path in pipe:lines() do out[#out + 1] = path end
  local ok = pipe:close()
  if ok == false then fail('cannot enumerate ' .. root) end
  table.sort(out)
  return out
end

local function module_name(path)
  local relative = assert(path:match('^src/(.+)$'))
  relative = relative:gsub('%.lua$', ''):gsub('/init$', '')
  return relative:gsub('/', '.')
end

local function collect_modules()
  local modules = {}
  for _, path in ipairs(list_files('src')) do
    local name = module_name(path)
    if modules[name] then fail('duplicate module ' .. name) end
    modules[name] = path
  end
  return modules
end

local function static_requirements(text)
  local names, seen = {}, {}
  for name in text:gmatch("require%s*%(%s*['\"]([^'\"]+)['\"]%s*%)") do
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function has_dynamic_require(text)
  local scrubbed = text:gsub("require%s*%(%s*['\"][^'\"]+['\"]%s*%)", '')
  return scrubbed:match('^%s*require%s*%(') ~= nil
    or scrubbed:match('[^%w_%.:]require%s*%(') ~= nil
end

local function parse_args(argv)
  local opts = { entries = {} }
  local i = 1
  while i <= #argv do
    local arg = argv[i]
    if arg == '--profile' then
      i = i + 1; opts.profile = argv[i]
    elseif arg == '--entry' then
      i = i + 1; opts.entries[#opts.entries + 1] = argv[i]
    elseif arg == '--output' then
      i = i + 1; opts.output = argv[i]
    elseif arg == '--bundle' then
      i = i + 1; opts.bundle = argv[i]
    elseif arg == '--report' then
      i = i + 1; opts.report = argv[i]
    elseif arg == '--allow-dynamic-require' then
      opts.allow_dynamic_require = true
    elseif arg == '--help' or arg == '-h' then
      io.write([[usage: lua scripts/build-profile.lua [options]
  --profile NAME              start from a named example profile
  --entry MODULE              add an arbitrary root module; repeatable
  --output DIR                emit a reduced Lua module tree
  --bundle FILE               emit one package.preload bundle
  --report FILE               write the size/package report
  --allow-dynamic-require     permit selected modules with dynamic require
]])
      os.exit(0)
    else
      fail('unknown argument: ' .. tostring(arg))
    end
    if argv[i] == nil and (arg == '--profile' or arg == '--entry' or arg == '--output' or arg == '--bundle' or arg == '--report') then
      fail(arg .. ' requires a value')
    end
    i = i + 1
  end
  return opts
end

local function add_entries(dst, values)
  for i = 1, #(values or {}) do dst[#dst + 1] = values[i] end
end

local function owner_of(name)
  local package = Ownership.owner(name)
  return package and package.name or 'unclassified'
end

local function resolve(modules, entries, allow_dynamic)
  local selected, queue = {}, {}
  for i = 1, #entries do queue[#queue + 1] = entries[i] end
  local head = 1
  while head <= #queue do
    local name = queue[head]
    head = head + 1
    if not selected[name] then
      local path = modules[name]
      if not path then fail('unknown module entry or dependency: ' .. tostring(name)) end
      selected[name] = path
      local text = read_file(path)
      if has_dynamic_require(text) and not allow_dynamic and not dynamic_requirements[name] then
        fail(name .. ' contains an undeclared dynamic require; declare it in packages/dynamic_requires.lua or pass --allow-dynamic-require')
      end
      for _, dependency in ipairs(static_requirements(text)) do
        if dependency == 'ffi' or dependency == 'cffi' or dependency == 'nixio' or dependency == 'nixio.fs' then
          -- External runtime dependencies are supplied by the selected backend.
        elseif modules[dependency] then
          queue[#queue + 1] = dependency
        end
      end
    end
  end
  return selected
end

local function sorted_names(selected)
  local names = {}
  for name in pairs(selected) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function output_path(root, source_path)
  return root .. '/' .. assert(source_path:match('^src/(.+)$'))
end

local function emit_tree(selected, output)
  for name, path in pairs(selected) do
    write_file(output_path(output, path), read_file(path))
  end
end

local function long_bracket(text)
  local eq = ''
  while text:find(']' .. eq .. ']', 1, true) do eq = eq .. '=' end
  return '[' .. eq .. '[' .. text .. ']' .. eq .. ']'
end

local function emit_bundle(selected, entries, path)
  local out = {
    '-- Generated exact-closure Fibers bundle; do not edit.\n',
    'local loaders = package.preload\n',
    'local compile = loadstring or load\n',
  }
  for _, name in ipairs(sorted_names(selected)) do
    out[#out + 1] = 'loaders[' .. string.format('%q', name) .. '] = assert(compile('
      .. long_bracket(read_file(selected[name])) .. ', '
      .. string.format('%q', '@' .. selected[name]) .. '))\n'
  end
  out[#out + 1] = 'return require(' .. string.format('%q', entries[1]) .. ')\n'
  write_file(path, table.concat(out))
end

local function make_report(selected, entries, description)
  local packages, total = {}, 0
  local lines = {}
  for _, name in ipairs(sorted_names(selected)) do
    local path = selected[name]
    local bytes = #read_file(path)
    total = total + bytes
    local owner = owner_of(name)
    local record = packages[owner] or { modules = 0, bytes = 0 }
    packages[owner] = record
    record.modules = record.modules + 1
    record.bytes = record.bytes + bytes
    lines[#lines + 1] = string.format('%8d  %-24s  %s', bytes, owner, name)
  end
  local summary = { 'Fibers exact-closure build' }
  if description then summary[#summary + 1] = 'Profile: ' .. description end
  summary[#summary + 1] = 'Entries: ' .. table.concat(entries, ', ')
  summary[#summary + 1] = string.format('Modules: %d', #sorted_names(selected))
  summary[#summary + 1] = string.format('Source bytes: %d', total)
  summary[#summary + 1] = ''
  summary[#summary + 1] = 'Package contribution:'
  for _, package in ipairs(catalogue) do
    local record = packages[package.name]
    if record then
      summary[#summary + 1] = string.format('  %-24s %4d modules %9d bytes', package.name, record.modules, record.bytes)
    end
  end
  summary[#summary + 1] = ''
  summary[#summary + 1] = 'Modules:'
  for i = 1, #lines do summary[#summary + 1] = '  ' .. lines[i] end
  return table.concat(summary, '\n') .. '\n'
end

local opts = parse_args(arg)
local profile = opts.profile and profiles[opts.profile] or nil
if opts.profile and not profile then fail('unknown profile: ' .. tostring(opts.profile)) end
local entries = {}
add_entries(entries, profile and profile.entries)
add_entries(entries, opts.entries)
if #entries == 0 then fail('select --profile or at least one --entry') end

local selected = resolve(collect_modules(), entries, opts.allow_dynamic_require or (profile and profile.allow_dynamic_require))
if opts.output then emit_tree(selected, opts.output) end
if opts.bundle then emit_bundle(selected, entries, opts.bundle) end
local report = make_report(selected, entries, profile and (opts.profile .. ' — ' .. profile.description) or nil)
if opts.report then write_file(opts.report, report) else io.write(report) end
