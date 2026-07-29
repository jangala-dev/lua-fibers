-- Parse Lua source without executing it.
--
-- Explicit paths are accepted for Makefile use. With no arguments, check every
-- repository Lua file in the maintained source, tooling and test trees.

local paths = {}
for i = 1, #arg do paths[#paths + 1] = arg[i] end

if #paths == 0 then
  local roots = {
    'src',
    'reference',
    'examples',
    'performance',
    'scripts',
    'tests',
    'packages',
  }
  for i = 1, #roots do
    local pipe = assert(io.popen("find '" .. roots[i] .. "' -type f -name '*.lua' -print", 'r'))
    for path in pipe:lines() do paths[#paths + 1] = path end
    assert(pipe:close() ~= false, 'cannot enumerate ' .. roots[i])
  end
  table.sort(paths)
end

local errors = {}
for i = 1, #paths do
  local path = paths[i]
  local chunk, message = loadfile(path)
  if not chunk then errors[#errors + 1] = path .. ': ' .. tostring(message) end
end

if #errors > 0 then
  io.stderr:write('Lua syntax errors:\n')
  for i = 1, #errors do io.stderr:write('  ', errors[i], '\n') end
  os.exit(1)
end

print('Lua script syntax: ok (' .. tostring(#paths) .. ' files)')
