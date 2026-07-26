-- Check only module properties required for reliable builds.

local function fail(message)
  io.stderr:write(message, '\n')
  os.exit(1)
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
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

local function read_file(path)
  local file, err = io.open(path, 'rb')
  if not file then
    fail(err or ('cannot read ' .. path))
  end
  local text = file:read('*a')
  file:close()
  return text
end

local function module_name(path, root)
  local relative = assert(path:match('^' .. root .. '/(.+)$'))
  relative = relative:gsub('%.lua$', ''):gsub('/init$', '')
  return relative:gsub('/', '.')
end

local function check_unambiguous_paths(paths, root, errors)
  local entries = {}
  for i = 1, #paths do
    local path = paths[i]
    local relative = assert(path:match('^' .. root .. '/(.+)$'))
    entries[#entries + 1] = {
      path = path,
      stem = relative:gsub('%.lua$', ''),
    }
  end
  for i = 1, #entries do
    local entry = entries[i]
    if not entry.stem:match('/init$') then
      local prefix = entry.stem .. '/'
      for j = 1, #entries do
        local child = entries[j]
        if child.stem:sub(1, #prefix) == prefix then
          errors[#errors + 1] = 'ambiguous module path: ' .. entry.path
            .. ' coexists with child module ' .. child.path
          break
        end
      end
    end
  end
end

local modules = {}
local errors = {}
for _, root in ipairs({ 'src', 'reference' }) do
  local paths = list_files('find ' .. shell_quote(root) .. " -type f -name '*.lua' -print")
  check_unambiguous_paths(paths, root, errors)
  for _, path in ipairs(paths) do
    local name = module_name(path, root)
    if modules[name] then
      errors[#errors + 1] = 'duplicate module ' .. name .. ': ' .. modules[name] .. ' and ' .. path
    else
      modules[name] = path
    end
  end
end

for _, root in ipairs({ 'src', 'reference', 'tests', 'examples', 'performance', 'scripts' }) do
  for _, path in ipairs(list_files('find ' .. shell_quote(root) .. " -type f -name '*.lua' -print")) do
    local text = read_file(path)
    local line = 1
    local offset = 1
    while true do
      local start_at, end_at, dependency = text:find("require%s*%(?%s*['\"](fibers[%w_%.]*)['\"]%s*%)?", offset)
      if not start_at then
        break
      end
      line = line + select(2, text:sub(offset, start_at - 1):gsub('\n', '\n'))
      if not modules[dependency] then
        errors[#errors + 1] = path .. ':' .. tostring(line) .. ': unresolved module ' .. dependency
      end
      offset = end_at + 1
    end
  end
end

if #errors > 0 then
  table.sort(errors)
  io.stderr:write('module errors:\n')
  for i = 1, #errors do
    io.stderr:write('  ', errors[i], '\n')
  end
  os.exit(1)
end

local count = 0
for _ in pairs(modules) do
  count = count + 1
end
print('modules: ok (' .. tostring(count) .. ')')
