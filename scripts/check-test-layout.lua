-- Validate stock-Lua test grouping independently of the Luau profile builder.

package.path = table.concat({
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local groups = require('tests.groups')
local profiles = require('tests.profiles')
local errors = {}
local owners = {}

local function add_error(message)
  errors[#errors + 1] = message
end

for group_name, tests in pairs(groups) do
  if type(group_name) ~= 'string' or type(tests) ~= 'table' then
    add_error('invalid test group entry: ' .. tostring(group_name))
  else
    for i = 1, #tests do
      local path = tests[i]
      if type(path) ~= 'string' then
        add_error(group_name .. ' contains a non-string test path')
      else
        local handle = io.open(path, 'rb')
        if not handle then
          add_error(group_name .. ' references missing test ' .. path)
        else
          handle:close()
          local previous = owners[path]
          if previous then
            add_error(path .. ' belongs to both ' .. previous .. ' and ' .. group_name)
          else
            owners[path] = group_name
          end
        end
      end
    end
  end
end

for profile_name, order in pairs(profiles) do
  local seen = {}
  if type(order) ~= 'table' then
    add_error('invalid test profile ' .. tostring(profile_name))
  else
    for i = 1, #order do
      local group_name = order[i]
      if not groups[group_name] then
        add_error(profile_name .. ' references unknown group ' .. tostring(group_name))
      elseif seen[group_name] then
        add_error(profile_name .. ' repeats group ' .. group_name)
      else
        seen[group_name] = true
      end
    end
  end
end

local pipe = assert(io.popen("find tests -type f -name 'test_*.lua' -print", 'r'))
local actual = {}
for path in pipe:lines() do
  actual[path] = true
  if not owners[path] then
    add_error('ungrouped test file ' .. path)
  end
end
pipe:close()

for path, group_name in pairs(owners) do
  if not actual[path] then
    add_error(group_name .. ' lists a non-test path ' .. path)
  end
end

if #errors > 0 then
  table.sort(errors)
  io.stderr:write('test layout errors:\n')
  for i = 1, #errors do
    io.stderr:write('  ', errors[i], '\n')
  end
  os.exit(1)
end

local count = 0
for _ in pairs(actual) do
  count = count + 1
end
print('test layout: ok (' .. tostring(count) .. ' tests)')
