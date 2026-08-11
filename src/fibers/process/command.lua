-- Immutable child-process command specifications and redirections.

local Contract = require('fibers.internal.contract')

local CommandModule = {}
local Command = {}
Command.__index = Command

local COMMAND_FIELDS = {
  argv = true, stdin = true, stdout = true, stderr = true, cwd = true,
  env = true, env_mode = true, unset_env = true, shutdown = true,
  process_group = true, pass_fds = true, close_fds = true, label = true,
}

local function copy_list(value, label, item)
  if value == nil then return {} end
  Contract.dense(value, label or 'list', 3, item)
  local out = {}
  for i = 1, #value do out[i] = value[i] end
  return out
end

local function validate_process_group(value, level)
  if value == nil or value == 'inherit' or value == 'new' then return value end
  if type(value) == 'number' then
    return Contract.non_negative_integer(value, 'process group', level or 3)
  end
  error("process group must be nil, 'inherit', 'new' or a non-negative integer group", level or 3)
end

local function validate_command_keys(input)
  local n = #input
  for key in pairs(input) do
    if type(key) == 'number' then
      if key < 1 or key ~= math.floor(key) or key > n then
        error('process.command positional argv must be a dense array', 3)
      end
    elseif not COMMAND_FIELDS[key] then
      error('process.command does not accept ' .. tostring(key), 3)
    end
  end
end

local copy_table = Contract.copy_table

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

local function signal(value, label, level)
  if type(value) ~= 'string' and type(value) ~= 'number' then
    error(label .. ' must be a signal name or number', level or 3)
  end
  return value
end

local SHUTDOWN_OPTIONS = {
  grace = Contract.non_negative_number, signal = signal, kill_signal = signal, target = true,
}

local function normalise_shutdown(value)
  value = copy_table(Contract.record(value, SHUTDOWN_OPTIONS, 'process shutdown', 3), 'process shutdown')
  value.grace = value.grace or 1.0
  value.signal = value.signal or 'term'
  value.kill_signal = value.kill_signal or 'kill'
  value.target = value.target or 'process'
  if value.target ~= 'process' and value.target ~= 'group' then error("shutdown.target must be 'process' or 'group'", 3) end
  return value
end

local function parse_command(...)
  local n = select('#', ...)
  if n == 1 and type((...)) == 'table' then
    local input = (...)
    validate_command_keys(input)
    local spec = copy_table(input)
    local argv = input.argv and copy_list(input.argv, 'process command argv', Contract.non_empty_string) or {}
    if #argv == 0 then
      for i = 1, #input do
        local value = input[i]
        Contract.non_empty_string(value, 'process command argv[' .. i .. ']', 3)
        argv[i] = value
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
    spec.env = copy_table(spec.env, 'process command env')
    for key, value in pairs(spec.env) do
      if type(key) ~= 'string' or key == '' or type(value) ~= 'string' then
        error('process command env must map non-empty string names to strings', 3)
      end
    end
    spec.unset_env = copy_list(spec.unset_env, 'process command unset_env', Contract.non_empty_string)
    spec.pass_fds = copy_list(spec.pass_fds, 'process command pass_fds', Contract.non_negative_integer)
    validate_process_group(spec.process_group, 3)
    spec.shutdown = normalise_shutdown(spec.shutdown)
    Contract.optional_boolean(spec.close_fds, 'process command close_fds', 3)
    spec.close_fds = spec.close_fds == nil and true or spec.close_fds
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
  opts = Contract.options(opts, { shell = true, stdin = true, stdout = true, stderr = true, cwd = true, env = true, env_mode = true, unset_env = true, shutdown = true, process_group = true, pass_fds = true, close_fds = true, label = true }, 'process.shell options', 2)
  opts = copy_table(opts, 'process.shell options')
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
  opts = Contract.record(opts, { close = Contract.boolean, flush = Contract.boolean }, 'process.redirect options', 2)
  return {
    _fibers_process_redirect = true,
    stream = stream,
    close = opts.close or false,
    flush = opts.flush == nil and true or opts.flush,
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
  opts = Contract.options(opts, { mode = true, unset = true }, 'Command:with_env options', 2)
  local spec = copy_spec(self._spec)
  spec.env = copy_table(values, 'Command:with_env values')
  for key, value in pairs(spec.env) do
    if type(key) ~= 'string' or key == '' or type(value) ~= 'string' then
      error('Command:with_env values must map non-empty string names to strings', 2)
    end
  end
  spec.env_mode = opts.mode or spec.env_mode or 'extend'
  spec.unset_env = copy_list(opts.unset == nil and spec.unset_env or opts.unset, 'Command:with_env unset', Contract.non_empty_string)
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
  return with_field(self, 'process_group', validate_process_group(value, 2))
end

CommandModule.Command = Command
CommandModule.copy_table = copy_table
CommandModule.copy_list = copy_list
CommandModule.copy_spec = copy_spec

return CommandModule
