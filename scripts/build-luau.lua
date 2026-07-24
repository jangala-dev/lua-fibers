-- Build the portable Fibers target for the standalone Luau CLI.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local profile_data = require('tests.luau.profile')

local function fail(message)
  error(message, 0)
end

local function read_file(path)
  local file, err = io.open(path, 'rb')
  if not file then
    fail(err or ('cannot read ' .. path))
  end
  local text = file:read('*a')
  file:close()
  return text
end

local function command_ok(command)
  local a, _, c = os.execute(command)
  return a == true or a == 0 or c == 0
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function mkdir(path)
  if path ~= '' and not command_ok('mkdir -p ' .. shell_quote(path)) then
    fail('cannot create directory ' .. path)
  end
end

local function dirname(path)
  return path:match('^(.*)/[^/]+$') or ''
end

local function write_file(path, text)
  mkdir(dirname(path))
  local file, err = io.open(path, 'wb')
  if not file then
    fail(err or ('cannot write ' .. path))
  end
  file:write(text)
  file:close()
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function list_files(command)
  local pipe = assert(io.popen(command, 'r'))
  local paths = {}
  for path in pipe:lines() do
    paths[#paths + 1] = path
  end
  local ok = pipe:close()
  if ok == false then
    fail('file discovery failed: ' .. command)
  end
  table.sort(paths)
  return paths
end

local function module_name(path, root, prefix)
  local relative = assert(path:match('^' .. root:gsub('([^%w])', '%%%1') .. '/(.+)$'))
  relative = relative:gsub('%.lua$', '')
  relative = relative:gsub('/init$', '')
  local name = relative:gsub('/', '.')
  if prefix then
    return prefix .. (name ~= '' and ('.' .. name) or '')
  end
  return name
end

local function collect_modules(roots, auxiliary)
  local modules = {}
  for i = 1, #roots do
    local root = roots[i]
    local prefix = auxiliary and root or nil
    local paths = list_files("find " .. shell_quote(root) .. " -type f -name '*.lua' -print")
    for j = 1, #paths do
      local path = paths[j]
      local name = module_name(path, root, prefix)
      if modules[name] then
        fail('duplicate module ' .. name .. ': ' .. modules[name] .. ' and ' .. path)
      end
      modules[name] = path
    end
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

local function resolve_profile(name, stack)
  stack = stack or {}
  if stack[name] then
    fail('cyclic Luau profile inheritance at ' .. name)
  end
  local raw = profile_data.profiles[name]
  if type(raw) ~= 'table' then
    fail('unknown Luau profile: ' .. tostring(name))
  end
  stack[name] = true
  local profile = raw.extends and resolve_profile(raw.extends, stack) or { tests = {}, module_entries = {} }
  stack[name] = nil

  local tests = {}
  local source_tests = raw.tests or profile.tests or {}
  for i = 1, #source_tests do
    tests[#tests + 1] = source_tests[i]
  end
  local excluded = {}
  for i = 1, #(raw.exclude or {}) do
    excluded[raw.exclude[i]] = true
  end
  local kept = {}
  for i = 1, #tests do
    if not excluded[tests[i]] then
      kept[#kept + 1] = tests[i]
    end
  end
  for i = 1, #(raw.include or {}) do
    local path = raw.include[i]
    local present = false
    for j = 1, #kept do
      present = present or kept[j] == path
    end
    if not present then
      kept[#kept + 1] = path
    end
  end

  local entries, seen = {}, {}
  for i = 1, #(profile.module_entries or {}) do
    local entry = profile.module_entries[i]
    entries[#entries + 1], seen[entry] = entry, true
  end
  for i = 1, #(raw.module_entries or {}) do
    local entry = raw.module_entries[i]
    if not seen[entry] then
      entries[#entries + 1], seen[entry] = entry, true
    end
  end
  return {
    name = name,
    machine = raw.machine or profile.machine or 'ledger',
    tests = kept,
    module_entries = entries,
  }
end

local function validate_profile(profile)
  local actual = list_files("find tests -type f -name 'test_*.lua' -print")
  local actual_set = {}
  for i = 1, #actual do
    actual_set[actual[i]] = true
    if not profile_data.classifications[actual[i]] then
      fail('unclassified Luau test: ' .. actual[i])
    end
  end
  for path in pairs(profile_data.classifications) do
    if not actual_set[path] then
      fail('stale Luau test classification: ' .. path)
    end
  end
  local seen = {}
  for i = 1, #profile.tests do
    local path = profile.tests[i]
    if seen[path] then
      fail('duplicate test in Luau profile: ' .. path)
    end
    seen[path] = true
    if profile_data.classifications[path] ~= 'portable' then
      fail('non-portable test in Luau profile: ' .. path)
    end
    if not actual_set[path] then
      fail('missing Luau profile test: ' .. path)
    end
  end
end

local function alias_name(name)
  local root, rest = name:match('^([^.]+)%.?(.*)$')
  if root ~= 'fibers' and root ~= 'tests' and root ~= 'examples' and root ~= 'experiments' then
    return name
  end
  if rest == '' then
    return '@' .. root
  end
  return '@' .. root .. '/' .. rest:gsub('%.', '/')
end

local function is_fibers_module(name)
  if name == 'fibers' then
    return true
  end
  if name:sub(1, 7) ~= 'fibers.' or name:sub(-1) == '.' or name:find('..', 1, true) then
    return false
  end
  for segment in name:gmatch('[^.]+') do
    if not segment:match('^[%a_][%w_]*$') then
      return false
    end
  end
  return true
end

local function transform(text)
  text = text:gsub("'(fibers[^']*)'", function(name)
    return is_fibers_module(name) and ("'" .. alias_name(name) .. "'") or ("'" .. name .. "'")
  end)
  text = text:gsub('"(fibers[^"]*)"', function(name)
    return is_fibers_module(name) and ('"' .. alias_name(name) .. '"') or ('"' .. name .. '"')
  end)
  text = text:gsub("require%s*%(%s*'([^']+)'%s*%)", function(name)
    return "require('" .. alias_name(name) .. "')"
  end)
  text = text:gsub('require%s*%(%s*"([^"]+)"%s*%)', function(name)
    return 'require("' .. alias_name(name) .. '")'
  end)
  return text
end

local function transform_source(name, text, machine)
  text = transform(text)
  if name == 'fibers.runtime' then
    local count
    text, count = text:gsub('local requested = opts%.machine',
      'local requested = opts.machine or ' .. string.format('%q', machine), 1)
    if count ~= 1 then
      fail("cannot set generated Luau runtime's default machine")
    end
  end
  return text
end

local function strip_loader(text, path)
  text = text:gsub("package%.path%s*=%s*table%.concat%s*%(%s*%b{}%s*,%s*['\"]%;['\"]%s*%)%s*", '')
  if text:find('package%.path') then
    fail('unrecognised package.path setup in portable test ' .. path)
  end
  if text:find('%f[%a]dofile%f[%A]') or text:find('%f[%a]loadfile%f[%A]') then
    fail('stock-Lua file loader remains in portable test ' .. path)
  end
  if text:find('package%.loaded') or text:find('package%.preload') then
    fail('stock-Lua module cache remains in portable test ' .. path)
  end
  if text:find('os%s*%.%s*getenv%s*%(') then
    fail('portable semantic test reads the process environment: ' .. path)
  end
  return text
end

local io_shim = [[local io = {
  write = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      parts[i] = tostring(select(i, ...))
    end
    local text = table.concat(parts)
    if string.sub(text, -1) == '\n' then
      text = string.sub(text, 1, -2)
    end
    print(text)
  end,
}

]]

local function wrap_test(text, path)
  local body = transform(strip_loader(text, path))
  local prelude = body:find('%f[%a]io%.') and io_shim or ''
  return '-- Generated from ' .. path .. '; do not edit.\nreturn function()\n'
    .. prelude .. body:gsub('%s+$', '') .. '\nend\n'
end

local function generated_path(path, auxiliary)
  if auxiliary then
    return 'src/' .. path:gsub('%.lua$', '.luau')
  end
  return 'src/' .. path:gsub('^src/', ''):gsub('^reference/', ''):gsub('%.lua$', '.luau')
end

local function profile_dependencies(test_paths, source, auxiliary)
  local source_entries, selected_aux, visited = {}, {}, {}
  local queue = {}
  for i = 1, #test_paths do
    queue[#queue + 1] = test_paths[i]
  end
  local head = 1
  while head <= #queue do
    local path = queue[head]
    head = head + 1
    if not visited[path] then
      visited[path] = true
      for _, dependency in ipairs(static_requirements(read_file(path))) do
        if source[dependency] then
          source_entries[dependency] = true
        elseif auxiliary[dependency] and not selected_aux[dependency] then
          selected_aux[dependency] = true
          queue[#queue + 1] = auxiliary[dependency]
        end
      end
    end
  end
  return source_entries, selected_aux
end

local function source_closure(modules, entries)
  local selected, queue = {}, {}
  for entry in pairs(entries) do
    if not modules[entry] then
      fail('missing portable entry module: ' .. entry)
    end
    queue[#queue + 1] = entry
  end
  table.sort(queue)
  local head = 1
  while head <= #queue do
    local name = queue[head]
    head = head + 1
    if not selected[name] then
      selected[name] = true
      for _, dependency in ipairs(static_requirements(read_file(modules[name]))) do
        if modules[dependency] and not selected[dependency] then
          queue[#queue + 1] = dependency
        end
      end
    end
  end
  return selected
end

local function render_runner(name, tests)
  local lines = {
    '-- Generated Luau test runner for profile ' .. name .. '; do not edit.',
    'local tests = {',
  }
  for i = 1, #tests do
    local path = tests[i]
    local module = path:gsub('%.lua$', ''):gsub('/', '.')
    lines[#lines + 1] = '  {'
    lines[#lines + 1] = '    name = ' .. string.format('%q', path) .. ','
    lines[#lines + 1] = '    run = function()'
    lines[#lines + 1] = '      local test = require(' .. string.format('%q', alias_name(module)) .. ')'
    lines[#lines + 1] = '      return test()'
    lines[#lines + 1] = '    end,'
    lines[#lines + 1] = '  },'
  end
  local tail = [[}

local passed, skipped, failed = 0, 0, 0
local failures = {}
print(string.format('tests/luau/PROFILE: running %d tests', #tests))
for i = 1, #tests do
  local test = tests[i]
  local ok, result = pcall(test.run)
  local is_skip = ok and type(result) == 'table' and (result.status == 'skip' or result.tag == 'skip')
  if not ok then
    failed = failed + 1
    failures[#failures + 1] = test.name .. ': ' .. tostring(result)
    print('FAIL ' .. test.name .. ' ' .. tostring(result))
  elseif is_skip then
    skipped = skipped + 1
    print('skip ' .. test.name .. ' ' .. tostring(result.reason or result.message or 'skipped'))
  else
    passed = passed + 1
    print('ok   ' .. test.name)
  end
end
print(string.format('tests/luau/PROFILE: summary: %d ok, %d skipped, %d failed, %d total', passed, skipped, failed, #tests))
if failed > 0 then
  error(table.concat(failures, '\n'), 0)
end
return true
]]
  tail = tail:gsub('PROFILE', name)
  lines[#lines + 1] = tail
  return table.concat(lines, '\n')
end

local output, profile_name = 'build/luau', 'portable'
local i = 1
while i <= #arg do
  if arg[i] == '--output' then
    i = i + 1
    output = arg[i] or fail('--output requires a value')
  elseif arg[i] == '--profile' then
    i = i + 1
    profile_name = arg[i] or fail('--profile requires a value')
  else
    fail('unknown argument: ' .. tostring(arg[i]))
  end
  i = i + 1
end
if
  output:sub(1, 1) == '/'
  or output == '..'
  or output:sub(1, 3) == '../'
  or output:find('/../', 1, true)
  or output:sub(-3) == '/..'
then
  fail('Luau output must remain within the repository')
end

local profile = resolve_profile(profile_name)
if profile.machine ~= 'ledger' and profile.machine ~= 'reference' then
  fail('invalid Luau machine: ' .. tostring(profile.machine))
end
validate_profile(profile)

local source = collect_modules({ 'src', 'reference' }, false)
local auxiliary = collect_modules({ 'tests', 'examples', 'experiments' }, true)
local test_entries, selected_aux = profile_dependencies(profile.tests, source, auxiliary)
local entries = {}
for j = 1, #profile_data.entries do
  entries[profile_data.entries[j]] = true
end
for entry in pairs(test_entries) do
  entries[entry] = true
end
for j = 1, #profile.module_entries do
  entries[profile.module_entries[j]] = true
end
local selected = source_closure(source, entries)

if not command_ok('rm -rf ' .. shell_quote(output)) then
  fail('cannot remove output directory ' .. output)
end
mkdir(output)

for _, name in ipairs(sorted_keys(selected)) do
  local path = source[name]
  write_file(output .. '/' .. generated_path(path, false), transform_source(name, read_file(path), profile.machine))
end
for _, name in ipairs(sorted_keys(selected_aux)) do
  local path = auxiliary[name]
  write_file(output .. '/' .. generated_path(path, true), transform(read_file(path)))
end
for j = 1, #profile.tests do
  local path = profile.tests[j]
  write_file(output .. '/src/' .. path:gsub('%.lua$', '.luau'), wrap_test(read_file(path), path))
end

local smoke = transform(read_file('tests/luau/smoke.lua'))
write_file(output .. '/tests/smoke.luau', smoke)
write_file(output .. '/tests/' .. profile_name .. '.luau', render_runner(profile_name, profile.tests))
write_file(output .. '/tests/profile.lua', read_file('tests/luau/profile.lua'))
write_file(output .. '/.luaurc', [[{
  "languageMode": "nocheck",
  "lint": { "*": false },
  "aliases": {
    "fibers": "./src/fibers",
    "tests": "./src/tests",
    "examples": "./src/examples",
    "experiments": "./src/experiments"
  }
}
]])
write_file(output .. '/README.md', '# Generated Luau build\n\nGenerated by `scripts/build-luau.lua`. Do not edit.\n')

if not read_file(output .. '/src/fibers/init.luau') then
  fail('missing generated Fibers entry point')
end
print(string.format('built %d portable Luau modules and %d %s tests in %s',
  #sorted_keys(selected), #profile.tests, profile_name, output))
