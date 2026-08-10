-- Portable evented regular-file provider using persistent helper processes.
-- Blocking filesystem calls occur only in the helper process; the Fibers side
-- uses ordinary evented process pipes.

local IOError = require('fibers.io.error')
local Process = require('fibers.process')
local unpack_ = table.unpack or unpack

local WorkerCommand = {}

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

function WorkerCommand.argv(opts, ...)
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

local Provider = {}
Provider.__index = Provider
local Backend = {}
Backend.__index = Backend

local function merged_opts(defaults, overrides)
  local out = {}
  for key, value in pairs(defaults or {}) do
    out[key] = value
  end
  for key, value in pairs(overrides or {}) do
    out[key] = value
  end
  return out
end

local function protocol_error(action, message, fields)
  return IOError.protocol('file', action, message, fields)
end

local function parse_header(line, action)
  if type(line) ~= 'string' then
    return nil, protocol_error(action, 'file worker closed unexpectedly')
  end
  local kind, a, b = line:match('^(%S+)%s+(%d+)%s*(%d*)$')
  if not kind then
    return nil, protocol_error(action, 'invalid file worker response', { payload = line })
  end
  return kind, tonumber(a), b ~= '' and tonumber(b) or nil
end

local function read_response(stream, action)
  local line, line_err = stream:read_line({ max = 4096 })
  if not line then
    return nil, IOError.normalise(line_err, { domain = 'file', action = action })
  end
  local kind, n, m = parse_header(line, action)
  if not kind then
    return nil, n
  end
  if kind == 'OK' or kind == 'DATA' then
    local payload = ''
    if n > 0 then
      payload, line_err = stream:read_exactly(n)
      if not payload then
        return nil, IOError.normalise(line_err, { domain = 'file', action = action })
      end
    end
    return payload, nil, kind
  end
  if kind == 'ERR' then
    local code = n > 0 and stream:read_exactly(n) or ''
    local message = m and m > 0 and stream:read_exactly(m) or ''
    if code == nil or message == nil then
      return nil, protocol_error(action, 'truncated file worker error')
    end
    if code == 'ENOTSUP' or code == 'EOPNOTSUPP' then
      return nil, IOError.unsupported('file', action, { message = message, code = code })
    end
    return nil, IOError.system('file', action, message, code)
  end
  return nil, protocol_error(action, 'unknown file worker response', { payload = line })
end

function Provider.new(runtime, opts)
  return setmetatable({ runtime = runtime, opts = opts or {}, name = 'worker' }, Provider)
end

function Provider:is_supported()
  local host = self.runtime and self.runtime.host
  return host and type(host.supports) == 'function' and host:supports('process')
end

function Provider:open(path, mode, opts)
  opts = merged_opts(self.opts, opts)
  if not self:is_supported() then
    return nil, IOError.unsupported('file', 'open', { path = path })
  end
  local argv = WorkerCommand.argv(
    opts,
    'handle',
    mode,
    path,
    tostring(opts.permissions or 420),
    opts.exclusive and '1' or '0'
  )
  local command = Process.command({ argv = argv, stdin = 'pipe', stdout = 'pipe', stderr = 'pipe' })
  local proc, err = command:start({ label = opts.label or ('file-worker:' .. path) })
  if not proc then
    return nil, IOError.normalise(err, { domain = 'file', action = 'open', path = path })
  end
  local _, greet_err = read_response(proc:stdout(), 'open')
  if greet_err then
    -- Release a helper which is waiting for failed-start acknowledgement only
    -- after its framed error has been consumed, then observe its natural exit
    -- before structurally closing the Process resource.
    local input = proc:stdin()
    if input then
      input:close('file worker open failed')
    end
    proc:result()
    proc:close('file worker open failed')
    return nil, greet_err
  end
  return setmetatable({
    provider = self,
    process = proc,
    input = proc:stdin(),
    output = proc:stdout(),
    path = path,
    closed = false,
  }, Backend)
end

function Backend:_request(action, header, payload)
  if self.closed then
    return nil, IOError.closed('file', action, { path = self.path })
  end
  local ok, err = self.input:write(header .. '\n')
  if not ok then
    return nil, IOError.normalise(err, { domain = 'file', action = action, path = self.path })
  end
  if payload and payload ~= '' then
    ok, err = self.input:write(payload)
    if not ok then
      return nil, IOError.normalise(err, { domain = 'file', action = action, path = self.path })
    end
  end
  ok, err = self.input:flush()
  if not ok then
    return nil, IOError.normalise(err, { domain = 'file', action = action, path = self.path })
  end
  return read_response(self.output, action)
end

function Backend:read(count)
  local value, err = self:_request('read', 'READ ' .. tostring(count))
  return value, err
end
function Backend:write(bytes)
  local value, err = self:_request('write', 'WRITE ' .. tostring(#bytes), bytes)
  if not value then
    return nil, err
  end
  return tonumber(value) or #bytes
end
function Backend:seek(whence, offset)
  local value, err = self:_request('seek', 'SEEK ' .. tostring(whence) .. ' ' .. tostring(offset))
  if not value then
    return nil, err
  end
  return tonumber(value)
end
function Backend:flush()
  local value, err = self:_request('flush', 'FLUSH')
  return value ~= nil, err
end
function Backend:sync(data_only)
  local value, err = self:_request('sync', 'SYNC ' .. (data_only and '1' or '0'))
  return value ~= nil, err
end
function Backend:close(reason)
  if self.closed then
    return true
  end
  local _, request_err = self:_request('close', 'CLOSE')
  self.closed = true

  -- CLOSE is a protocol request, not a cancellation request. Once it has been
  -- acknowledged, let the helper exit normally and reap it before asking the
  -- Process resource to close. This avoids racing natural exit against
  -- process shutdown and losing the final pipe state on some hosts.
  local status, result_err = self.process:result()
  local closed, close_err = self.process:close(reason or 'file closed')
  if request_err then
    return nil, request_err
  end
  if not Process.succeeded(status) then
    return nil, result_err or IOError.system('file', 'close', 'file worker failed')
  end
  if not closed then
    return nil, close_err
  end
  return true
end

function Provider:_path(action, args, opts)
  opts = merged_opts(self.opts, opts)
  if not self:is_supported() then
    return nil, IOError.unsupported('file', action:lower())
  end
  local argv = WorkerCommand.argv(opts, 'path', action, unpack_(args))
  local command = Process.command({ argv = argv, stdin = 'null', stdout = 'pipe', stderr = 'pipe' })
  local proc, err = command:start({ label = 'file-worker:' .. action:lower() })
  if not proc then
    return nil, IOError.normalise(err, { domain = 'file', action = action:lower() })
  end
  local value, response_err = read_response(proc:stdout(), action:lower())
  local status, result_err = proc:result()
  proc:close('path operation complete')
  if response_err then
    return nil, response_err
  end
  if not Process.succeeded(status) then
    return nil, result_err or IOError.system('file', action:lower(), 'file worker failed')
  end
  return value ~= nil
end
function Provider:rename(from, to, opts)
  return self:_path('RENAME', { from, to }, opts)
end
function Provider:unlink(path, opts)
  return self:_path('UNLINK', { path }, opts)
end
function Provider:mkdir(path, opts)
  return self:_path('MKDIR', { path, tostring((opts and opts.permissions) or 493) }, opts)
end
function Provider:mkdir_p(path, opts)
  return self:_path('MKDIRP', { path, tostring((opts and opts.permissions) or 493) }, opts)
end

Provider.Backend = Backend
return Provider
