local root = arg[1] or '.'
local command = table.concat({
  'find',
  string.format('%q', root),
  "-type d \\( -name .git -o -name build \\) -prune -o",
  "-type f -name '*.md' -print",
}, ' ')
local pipe = assert(io.popen(command, 'r'))
local missing = {}
local files_checked, links_checked = 0, 0

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

local function target_path(raw)
  local target = raw:gsub('^%s+', ''):gsub('%s+$', '')
  if target:sub(1, 1) == '<' then
    target = target:match('^<([^>]+)>') or target
  else
    target = target:match('^(%S+)') or target
  end
  target = target:match('^([^#?]+)') or ''
  return target
end

local function exists(path)
  local ok = os.rename(path, path)
  if ok then
    return true
  end
  local file = io.open(path, 'rb')
  if file then
    file:close()
    return true
  end
  return false
end

local function check_target(file, raw)
  local target = target_path(raw)
  if target == ''
    or target:match('^[a-zA-Z][a-zA-Z0-9+.-]*:')
    or target:sub(1, 1) == '#'
  then
    return
  end
  links_checked = links_checked + 1
  local path = normalise(dirname(file) .. '/' .. target)
  if not exists(path) then
    missing[#missing + 1] = file .. ' -> ' .. raw
  end
end

for file in pipe:lines() do
  files_checked = files_checked + 1
  local handle = assert(io.open(file, 'rb'))
  local text = handle:read('*a')
  handle:close()

  for target in text:gmatch('%[[^%]]-%]%(([^%)]+)%)') do
    check_target(file, target)
  end
  for target in text:gmatch('\n%s*%[[^%]]+%]:%s*([^\n]+)') do
    check_target(file, target)
  end
end
pipe:close()

if #missing > 0 then
  table.sort(missing)
  io.stderr:write('missing local Markdown links:\n')
  for i = 1, #missing do
    io.stderr:write('  ', missing[i], '\n')
  end
  os.exit(1)
end

print(
  'Markdown links: ok ('
    .. tostring(files_checked)
    .. ' files, '
    .. tostring(links_checked)
    .. ' local links)'
)
