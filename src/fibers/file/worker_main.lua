-- Standalone blocking regular-file worker. Protocol framing lives here; native
-- filesystem adaptation lives in the sibling native_sync.lua module. Neither
-- layer depends on the Fibers runtime.

local argv = _G.arg or {}

local function sibling(name)
  local info = debug and debug.getinfo and debug.getinfo(1, 'S')
  local source = info and info.source or nil
  local path = type(source) == 'string' and source:sub(1, 1) == '@' and source:sub(2) or (argv[0] or '')
  local dir = path:match('^(.*)[/\\][^/\\]+$') or '.'
  return assert(loadfile(dir .. '/' .. name))()
end
local NativeFile = sibling('internal/native_sync.lua')

local function write_all(bytes)
  local ok, err = io.stdout:write(bytes)
  if not ok then return nil, err end
  io.stdout:flush()
  return true
end
local function response_ok(value)
  if value == nil then return write_all('OK 0\n') end
  value = tostring(value)
  return write_all('OK ' .. tostring(#value) .. '\n' .. value)
end
local function response_data(value)
  value = value or ''
  return write_all('DATA ' .. tostring(#value) .. '\n' .. value)
end
local function response_error(code, message)
  code, message = tostring(code or 'EIO'), tostring(message or 'file operation failed')
  return write_all('ERR ' .. tostring(#code) .. ' ' .. tostring(#message) .. '\n' .. code .. message)
end
local function report(err, fallback)
  err = type(err) == 'table' and err or { code = fallback or 'EIO', message = err }
  return response_error(err.code or fallback, err.message)
end
local function read_exact(n)
  if n == 0 then return '' end
  local chunks, total = {}, 0
  while total < n do
    local chunk = io.stdin:read(n - total)
    if not chunk or chunk == '' then return nil, 'unexpected end of input' end
    chunks[#chunks + 1], total = chunk, total + #chunk
  end
  return table.concat(chunks)
end
local function line() return io.stdin:read('*l') end

local function handle_mode(mode, path, permissions, exclusive)
  local handle, err = NativeFile.open(path, mode, {
    permissions = permissions,
    exclusive = exclusive == '1',
  })
  if not handle then
    report(err, 'EOPEN')
    -- Keep the helper alive until the parent drains the final response.
    line()
    return 0
  end
  response_ok()
  while true do
    local request = line()
    if not request then handle:close(); return 0 end
    local op, rest = request:match('^(%S+)%s*(.*)$')
    if op == 'READ' then
      local count = tonumber(rest)
      if not count or count < 0 or count ~= math.floor(count) then
        response_error('EINVAL', 'READ expects a non-negative integer')
      else
        local data, read_err = handle:read(count)
        if data == nil then report(read_err, 'EREAD') else response_data(data) end
      end
    elseif op == 'WRITE' then
      local count = tonumber(rest)
      if not count or count < 0 or count ~= math.floor(count) then
        response_error('EINVAL', 'WRITE expects a non-negative integer')
      else
        local bytes, input_err = read_exact(count)
        if not bytes then response_error('EPROTO', input_err)
        else
          local written, write_err = handle:write(bytes)
          if written == nil then report(write_err, 'EWRITE') else response_ok(written) end
        end
      end
    elseif op == 'SEEK' then
      local whence, offset = rest:match('^(%S+)%s+([+-]?%d+)$')
      local position, seek_err = handle:seek(whence, tonumber(offset))
      if position == nil then report(seek_err, 'ESEEK') else response_ok(position) end
    elseif op == 'FLUSH' then
      local ok, flush_err = handle:flush()
      if not ok then report(flush_err, 'EFLUSH') else response_ok() end
    elseif op == 'SYNC' then
      local ok, sync_err = handle:sync(rest == '1')
      if not ok then report(sync_err, 'ESYNC') else response_ok() end
    elseif op == 'CLOSE' then
      local ok, close_err = handle:close()
      if not ok then report(close_err, 'ECLOSE') else response_ok() end
      return ok and 0 or 1
    else
      response_error('EPROTO', 'unknown request ' .. tostring(op))
    end
  end
end

local PATH_ACTIONS = {
  RENAME = function(args) return NativeFile.rename(args[1], args[2]) end,
  UNLINK = function(args) return NativeFile.unlink(args[1]) end,
  MKDIR = function(args) return NativeFile.mkdir(args[1], args[2]) end,
  MKDIRP = function(args) return NativeFile.mkdir_p(args[1], args[2]) end,
}
local function path_mode(action, args)
  local fn = PATH_ACTIONS[action]
  if not fn then response_error('EINVAL', 'unknown path action'); return 2 end
  local ok, err = fn(args)
  if not ok then report(err, 'E' .. action); return 1 end
  response_ok()
  return 0
end

local function main()
  local mode = argv[1]
  if mode == 'handle' then return handle_mode(argv[2], argv[3], argv[4], argv[5]) end
  if mode == 'path' then return path_mode(argv[2], { argv[3], argv[4], argv[5] }) end
  response_error('EINVAL', 'worker expects handle or path mode')
  return 2
end

local ok, status = xpcall(main, function(err)
  return debug and debug.traceback and debug.traceback(err, 2) or tostring(err)
end)
if not ok then
  response_error('EWORKER', status)
  line()
  status = 0
end
os.exit(status or 0)
