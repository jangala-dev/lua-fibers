-- Immutable child-process command specifications and redirections.

local CommandModule = {}
local Command = {}
Command.__index = Command

local function copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function copy_list(value)
  local out = {}
  for i = 1, #(value or {}) do
    out[i] = value[i]
  end
  return out
end

local function copy_spec(spec)
  local out = copy_table(spec)
  out.argv = copy_list(spec.argv)
  out.env = copy_table(spec.env)
  out.unset_env = copy_list(spec.unset_env)
  out.shutdown = copy_table(spec.shutdown)
  out.pass_fds = copy_list(spec.pass_fds)
  return out
end

local function command_value(spec)
  return setmetatable({ _spec = copy_spec(spec) }, Command)
end

local function is_stream(value)
  return type(value) == 'table'
    and (type(value.read_some_op) == 'function' or type(value.write_op) == 'function')
end

local function normalise_stdio(value, which)
  if value == nil then
    return 'inherit'
  end
  if is_stream(value) or (type(value) == 'table' and value._fibers_process_redirect) then
    return value
  end
  if value == 'inherit' or value == 'null' or value == 'pipe' then
    return value
  end
  if which == 'stderr' and value == 'stdout' then
    return value
  end
  local extra = which == 'stderr' and ", 'stdout'" or ''
  error(which .. " must be 'inherit', 'null', 'pipe'" .. extra .. ' or a Stream', 3)
end

local function normalise_shutdown(value)
  value = copy_table(value)
  if value.grace == nil then
    value.grace = 1.0
  end
  if type(value.grace) ~= 'number' or value.grace < 0 then
    error('shutdown.grace must be a non-negative number', 3)
  end
  value.signal = value.signal or 'term'
  value.kill_signal = value.kill_signal or 'kill'
  value.target = value.target or 'process'
  if value.target ~= 'process' and value.target ~= 'group' then
    error("shutdown.target must be 'process' or 'group'", 3)
  end
  return value
end

local function parse_command(...)
  local n = select('#', ...)
  if n == 1 and type((...)) == 'table' then
    local input = (...)
    local spec = copy_table(input)
    local argv = input.argv and copy_list(input.argv) or {}
    if #argv == 0 then
      for i = 1, #input do
        argv[i] = input[i]
      end
    end
    if #argv == 0 then
      error('process.command expects a non-empty argv', 3)
    end
    spec.argv = argv
    spec.stdin = normalise_stdio(spec.stdin, 'stdin')
    spec.stdout = normalise_stdio(spec.stdout, 'stdout')
    spec.stderr = normalise_stdio(spec.stderr, 'stderr')
    spec.env_mode = spec.env_mode or 'extend'
    if spec.env_mode ~= 'extend' and spec.env_mode ~= 'replace' then
      error("env_mode must be 'extend' or 'replace'", 3)
    end
    spec.env = copy_table(spec.env)
    spec.unset_env = copy_list(spec.unset_env)
    spec.shutdown = normalise_shutdown(spec.shutdown)
    spec.close_fds = spec.close_fds ~= false
    return spec
  end
  if n == 0 then
    error('process.command expects argv', 3)
  end
  local argv = {}
  for i = 1, n do
    local value = select(i, ...)
    if type(value) ~= 'string' then
      error('process.command varargs must be strings', 3)
    end
    argv[i] = value
  end
  return parse_command({ argv = argv })
end

function CommandModule.command(...)
  return command_value(parse_command(...))
end

function CommandModule.shell(script, opts)
  if type(script) ~= 'string' then
    error('process.shell expects a command string', 2)
  end
  opts = copy_table(opts)
  local shell = opts.shell or '/bin/sh'
  opts.shell = nil
  local spec = copy_table(opts)
  spec.argv = { shell, '-c', script }
  return command_value(parse_command(spec))
end

function CommandModule.redirect(stream, opts)
  if not is_stream(stream) then
    error('process.redirect expects a Stream', 2)
  end
  opts = copy_table(opts)
  return {
    _fibers_process_redirect = true,
    stream = stream,
    close = opts.close == true,
    flush = opts.flush ~= false,
  }
end

function CommandModule.redirect_stream(value)
  if type(value) == 'table' and value._fibers_process_redirect then
    return value.stream, value
  end
  if is_stream(value) then
    return value, { stream = value, close = false, flush = true }
  end
end

function Command:spec()
  return copy_spec(self._spec)
end

function Command:argv()
  return copy_list(self._spec.argv)
end

local function with_field(self, key, value)
  local spec = copy_spec(self._spec)
  spec[key] = value
  return command_value(spec)
end

function Command:with_cwd(path)
  if path ~= nil and type(path) ~= 'string' then
    error('with_cwd expects a path string or nil', 2)
  end
  return with_field(self, 'cwd', path)
end

function Command:with_env(values, opts)
  opts = opts or {}
  local spec = copy_spec(self._spec)
  spec.env = copy_table(values)
  spec.env_mode = opts.mode or spec.env_mode or 'extend'
  spec.unset_env = copy_list(opts.unset or spec.unset_env)
  if spec.env_mode ~= 'extend' and spec.env_mode ~= 'replace' then
    error("environment mode must be 'extend' or 'replace'", 2)
  end
  return command_value(spec)
end

function Command:with_stdin(value)
  return with_field(self, 'stdin', normalise_stdio(value, 'stdin'))
end

function Command:with_stdout(value)
  return with_field(self, 'stdout', normalise_stdio(value, 'stdout'))
end

function Command:with_stderr(value)
  return with_field(self, 'stderr', normalise_stdio(value, 'stderr'))
end

function Command:with_shutdown(value)
  return with_field(self, 'shutdown', normalise_shutdown(value))
end

function Command:with_process_group(value)
  if value ~= nil and value ~= 'inherit' and value ~= 'new' and type(value) ~= 'number' then
    error("process group must be nil, 'inherit', 'new' or a numeric group", 2)
  end
  return with_field(self, 'process_group', value)
end

CommandModule.Command = Command
CommandModule.copy_table = copy_table
CommandModule.copy_list = copy_list
CommandModule.copy_spec = copy_spec

return CommandModule
