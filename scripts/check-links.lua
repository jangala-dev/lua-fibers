local root = arg[1] or '.'
local command = "find " .. string.format('%q', root) .. " -type f -name '*.md' -print"
local pipe = assert(io.popen(command, 'r'))
local missing = {}

local function dirname(path)
  return path:match('^(.*)/[^/]*$') or '.'
end

local function normalise(path)
  local absolute = path:sub(1, 1) == '/'
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '..' then
      if #parts > 0 then
        table.remove(parts)
      end
    elseif part ~= '.' and part ~= '' then
      parts[#parts + 1] = part
    end
  end
  return (absolute and '/' or '') .. table.concat(parts, '/')
end

for file in pipe:lines() do
  local fh = assert(io.open(file, 'rb'))
  local text = fh:read('*a')
  fh:close()
  for target in text:gmatch('%[[^%]]-%]%(([^%)]+)%)') do
    target = target:gsub('^%s+', ''):gsub('%s+$', '')
    target = target:match('^([^#]+)') or ''
    if target ~= ''
      and not target:match('^[a-zA-Z][a-zA-Z0-9+.-]*:')
      and target:sub(1, 1) ~= '#'
    then
      local path = normalise(dirname(file) .. '/' .. target)
      local probe = io.open(path, 'rb')
      if probe then
        probe:close()
      else
        missing[#missing + 1] = file .. ' -> ' .. target
      end
    end
  end
end
pipe:close()

if #missing > 0 then
  io.stderr:write('missing local Markdown links:\n')
  for i = 1, #missing do
    io.stderr:write('  ', missing[i], '\n')
  end
  os.exit(1)
end

print('all local Markdown links resolve')
