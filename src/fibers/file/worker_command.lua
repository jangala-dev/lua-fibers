local Command = {}

local function source_path()
  local info = debug and debug.getinfo and debug.getinfo(1, 'S')
  local source = info and info.source or nil
  if type(source) == 'string' and source:sub(1, 1) == '@' then
    return source:sub(2)
  end
end

local function dirname(path)
  return path and path:match('^(.*)[/\\][^/\\]+$') or '.'
end

local function interpreter(opts)
  opts = opts or {}
  if type(opts.worker_command) == 'table' and #opts.worker_command > 0 then
    return opts.worker_command
  end
  local env = os.getenv('FIBERS_LUA')
  if env and env ~= '' then
    return { env }
  end
  local a = rawget(_G, 'arg')
  if type(a) == 'table' then
    for _, index in ipairs({ -1, -2 }) do
      local value = a[index]
      if type(value) == 'string' and value ~= '' and not value:match('^%-') then
        return { value }
      end
    end
  end
  return { 'lua' }
end

function Command.argv(opts, ...)
  opts = opts or {}
  local out = {}
  local base = interpreter(opts)
  for i = 1, #base do
    out[#out + 1] = base[i]
  end
  local worker = opts.worker_script or (dirname(source_path()) .. '/worker_main.lua')
  out[#out + 1] = worker
  for i = 1, select('#', ...) do
    out[#out + 1] = tostring(select(i, ...))
  end
  return out
end

return Command
