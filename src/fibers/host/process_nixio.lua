-- Evented Nixio child-process provider.
--
-- Nixio does not expose FD_CLOEXEC or setpgid.  A per-command reaper process
-- therefore owns the real child, reports terminal status over a non-blocking
-- sentinel pipe, and reaps it exactly once.  Parent-visible launch failures are
-- checked before fork and child setup failures are reported before the reaper
-- publishes the child pid.  The final exec transition cannot be proved without
-- close-on-exec support; hosts expose that limitation in their capabilities.

local HostError = require('fibers.host.error')
local IOAudit = require('fibers.internal.io_audit')
local ProviderModule = require('fibers.host.provider')
local Sleep = require('fibers.sleep')

local function unsupported(reason)
  return ProviderModule.unsupported('fibers.host.process_nixio', reason, {
    'start_process',
  })
end

local ok_nixio, nixio = pcall(require, 'nixio')
local ok_fs, fs = pcall(require, 'nixio.fs')
if not ok_nixio or type(nixio) ~= 'table' or not ok_fs or type(fs) ~= 'table' then
  return unsupported('requires nixio and nixio.fs')
end

local Fd = require('fibers.host.fd_nixio')
local Op = require('fibers.op')
local NixioError = require('fibers.host.nixio_error')
local Provider = {}
local const = nixio.const or {}

local signal_numbers = {
  hup = const.SIGHUP or 1,
  int = const.SIGINT or 2,
  quit = const.SIGQUIT or 3,
  kill = const.SIGKILL or 9,
  usr1 = const.SIGUSR1 or 10,
  usr2 = const.SIGUSR2 or 12,
  pipe = const.SIGPIPE or 13,
  alrm = const.SIGALRM or 14,
  term = const.SIGTERM or 15,
  chld = const.SIGCHLD or 17,
  cont = const.SIGCONT or 18,
  stop = const.SIGSTOP or 19,
}

local signal_names = {
  [signal_numbers.hup] = 'HUP',
  [signal_numbers.int] = 'INT',
  [signal_numbers.quit] = 'QUIT',
  [signal_numbers.kill] = 'KILL',
  [signal_numbers.term] = 'TERM',
}

local current_errno = NixioError.current_errno
local error_message = NixioError.detail

local function close_obj(obj)
  if obj and type(obj.close) == 'function' then
    local ok = pcall(function() obj:close() end)
    return ok
  end
  return true
end

local function set_blocking(obj, blocking)
  if not obj or type(obj.setblocking) ~= 'function' then return true end
  local ok, a, b = obj:setblocking(blocking)
  if ok ~= nil and ok ~= false then return true end
  local msg, eno = error_message('setblocking failed', a, b)
  return nil, msg, eno
end

local function write_all(obj, bytes)
  local offset = 0
  while offset < #bytes do
    local n, a, b = obj:write(bytes, offset, #bytes - offset)
    if type(n) == 'number' then
      if n <= 0 then return nil, 'short write', current_errno() end
      offset = offset + n
    elseif n == true then
      return true
    else
      local msg, eno = error_message('write failed', a, b)
      if eno ~= const.EINTR then return nil, msg, eno end
    end
  end
  return true
end

local function read_chunk(obj, max)
  local data, a, b = obj:read(max)
  if type(data) == 'string' then return data end
  local msg, eno = error_message('read failed', a, b)
  if data == false or eno == const.EAGAIN or eno == const.EWOULDBLOCK then
    return nil, 'would_block', eno
  end
  return nil, msg, eno
end

local function normalise_signal(value)
  if type(value) == 'number' and value > 0 and value == math.floor(value) then return value end
  if type(value) == 'string' then
    local key = value:lower():gsub('^sig', '')
    if signal_numbers[key] then return signal_numbers[key] end
  end
  return nil, HostError.invalid_argument('process', 'signal', { signal = value })
end

local function copy_environment(spec)
  local out = {}
  if spec.env_mode ~= 'replace' then
    local current, a, b = nixio.getenv()
    if current == nil then
      local msg, eno = error_message('get environment failed', a, b)
      return nil, HostError.system('process', 'environment', msg, nil, eno)
    end
    for name, value in pairs(current) do out[tostring(name)] = tostring(value) end
  end
  for _, name in ipairs(spec.unset_env or {}) do out[tostring(name)] = nil end
  for name, value in pairs(spec.env or {}) do out[tostring(name)] = tostring(value) end
  return out
end

local function absolute_base(cwd)
  if cwd and cwd:sub(1, 1) == '/' then return cwd end
  local here = type(nixio.getcwd) == 'function' and nixio.getcwd() or nil
  here = type(here) == 'string' and here or '.'
  if cwd and cwd ~= '' then return here .. '/' .. cwd end
  return here
end

local function access_exec(path)
  local ok, a, b = fs.access(path, 'f', 'x')
  if ok then return true end
  local msg, eno = error_message('executable is unavailable', a, b)
  return nil, msg, eno
end

local function preflight(spec, env)
  if type(spec.process_group) == 'number' then
    return nil, HostError.unsupported('process', 'process_group', {
      host = 'nixio', process_group = spec.process_group,
      message = 'Nixio cannot join an existing numeric process group',
    })
  end
  if spec.pass_fds and #spec.pass_fds > 0 then
    return nil, HostError.unsupported('process', 'pass_fds', {
      host = 'nixio',
      message = 'Nixio cannot control close-on-exec inheritance without a native supplement',
    })
  end
  if spec.cwd then
    local kind, a, b = fs.stat(spec.cwd, 'type')
    if kind ~= 'dir' then
      local msg, eno = error_message('working directory unavailable', a, b)
      return nil, HostError.system('process', 'chdir', msg, nil, eno, { cwd = spec.cwd })
    end
  end

  local program = tostring(spec.argv[1])
  local candidate
  if program:find('/', 1, true) then
    candidate = program:sub(1, 1) == '/' and program or (absolute_base(spec.cwd) .. '/' .. program)
    local ok, msg, eno = access_exec(candidate)
    if not ok then
      return nil, HostError.system('process', 'exec', msg, nil, eno, { argv = spec.argv })
    end
  else
    local path = env.PATH
    if path == nil or path == '' then path = '/bin:/usr/bin' end
    local base = absolute_base(spec.cwd)
    for part in (path .. ':'):gmatch('(.-):') do
      local dir = part == '' and base or part
      if dir:sub(1, 1) ~= '/' then dir = base .. '/' .. dir end
      local path_candidate = dir .. '/' .. program
      if access_exec(path_candidate) then
        candidate = path_candidate
        break
      end
    end
    if not candidate then
      return nil, HostError.system('process', 'exec', 'executable not found: ' .. program, 'ENOENT', const.ENOENT, {
        argv = spec.argv,
      })
    end
  end
  return candidate
end

local function make_pipe(action, fields)
  local r, w, a, b = nixio.pipe()
  if r and w then return r, w end
  local msg, eno = error_message('pipe failed', a, b)
  return nil, nil, HostError.system('process', action or 'pipe', msg, nil, eno, fields)
end

local function duplicate(source, target)
  local duped, a, b = nixio.dup(source, target)
  if duped then return true end
  return nil, error_message('dup failed', a, b)
end

local function child_fail(writer, stage, eno)
  write_all(writer, 'failed ' .. tostring(stage) .. ' ' .. tostring(tonumber(eno) or 0) .. '\n')
  close_obj(writer)
  os.exit(127)
end

local function child_stdio_setup(stdio)
  local function install(which, target)
    local mode = stdio[which]
    if mode == nil or mode == 'inherit' then return true end
    if which == 'stderr' and mode == 'stdout' then
      local ok, msg, eno = duplicate(nixio.stdout, nixio.stderr)
      return ok, msg, eno
    end
    local source
    if mode == 'pipe' then
      source = stdio[which .. '_child']
    elseif mode == 'null' then
      local a, b
      source, a, b = nixio.open('/dev/null', which == 'stdin' and 'r' or 'w')
      if not source then return nil, error_message('open /dev/null failed', a, b) end
      stdio.opened[#stdio.opened + 1] = source
    end
    if source then
      local ok, msg, eno = duplicate(source, target)
      if not ok then return nil, msg, eno end
    end
    return true
  end

  for _, item in ipairs({
    { 'stdin', nixio.stdin }, { 'stdout', nixio.stdout }, { 'stderr', nixio.stderr },
  }) do
    local ok, msg, eno = install(item[1], item[2])
    if not ok then return nil, msg, eno end
  end

  for _, obj in ipairs(stdio.all) do close_obj(obj) end
  for _, obj in ipairs(stdio.opened) do close_obj(obj) end
  return true
end

local function build_exec_args(argv)
  local args = {}
  for i = 2, #argv do args[#args + 1] = tostring(argv[i]) end
  return args
end

local function close_inherited(objects)
  for _, obj in ipairs(objects or {}) do
    local fd
    if obj and type(obj.fileno) == 'function' then
      local ok, value = pcall(function() return obj:fileno() end)
      if ok then fd = tonumber(value) end
    end
    if not fd or fd > 2 then close_obj(obj) end
  end
end

local function wait_child(pid, flag)
  while true do
    local got, how, value = flag and nixio.waitpid(pid, flag) or nixio.waitpid(pid)
    if got ~= nil then return got, how, value end
    local msg, eno = error_message('waitpid failed', how, value)
    if eno ~= const.EINTR then return nil, nil, nil, msg, eno end
  end
end

local function reaper_main(spec, exec_path, env, stdio, inherited, status_r, status_w)
  close_obj(status_r)
  close_inherited(inherited)
  local launch_r, launch_w = nixio.pipe()
  if not launch_r or not launch_w then
    local _, eno = error_message('launch pipe failed')
    write_all(status_w, 'failed pipe ' .. tostring(eno or 0) .. '\n')
    close_obj(status_w)
    os.exit(127)
  end

  local child_pid, a, b = nixio.fork()
  if child_pid == nil then
    local _, eno = error_message('fork failed', a, b)
    write_all(status_w, 'failed fork ' .. tostring(eno or 0) .. '\n')
    close_obj(launch_r); close_obj(launch_w); close_obj(status_w)
    os.exit(127)
  end

  if child_pid == 0 then
    close_obj(launch_r)
    close_obj(status_w)
    if spec.cwd then
      local ok, x, y = nixio.chdir(spec.cwd)
      if not ok then local _, eno = error_message('chdir failed', x, y); child_fail(launch_w, 'cwd', eno) end
    end
    if spec.new_session or spec.process_group == 'new' then
      local ok, x, y = nixio.setsid()
      if not ok then local _, eno = error_message('setsid failed', x, y); child_fail(launch_w, 'session', eno) end
    end
    local stdio_ok, _, stdio_eno = child_stdio_setup(stdio)
    if not stdio_ok then child_fail(launch_w, 'stdio', stdio_eno) end
    write_all(launch_w, 'ready\n')
    close_obj(launch_w)
    local args = build_exec_args(spec.argv)
    nixio.exece(exec_path, args, env)
    os.exit(127)
  end

  close_obj(launch_w)
  for _, obj in ipairs(stdio.all) do close_obj(obj) end

  local launch_buf = ''
  while true do
    local chunk, read_err, read_eno = read_chunk(launch_r, const.buffersize or 256)
    if not chunk then
      if read_err == 'would_block' then
        -- launch_r remains blocking here; this is only defensive.
      else
        local _, eno = error_message('launch handshake failed', read_err, read_eno)
        nixio.kill(child_pid, signal_numbers.kill)
        wait_child(child_pid)
        write_all(status_w, 'failed handshake ' .. tostring(eno or 0) .. '\n')
        close_obj(launch_r); close_obj(status_w)
        os.exit(127)
      end
    elseif chunk == '' then
      nixio.kill(child_pid, signal_numbers.kill)
      wait_child(child_pid)
      write_all(status_w, 'failed handshake 0\n')
      close_obj(launch_r); close_obj(status_w)
      os.exit(127)
    else
      launch_buf = launch_buf .. chunk
      local line, rest = launch_buf:match('^([^\n]*)\n(.*)$')
      if line then
        launch_buf = rest
        local stage, number = line:match('^failed ([%w_]+) (%d+)$')
        if stage then
          wait_child(child_pid)
          write_all(status_w, 'failed ' .. stage .. ' ' .. number .. '\n')
          close_obj(launch_r); close_obj(status_w)
          os.exit(127)
        elseif line == 'ready' then
          break
        else
          nixio.kill(child_pid, signal_numbers.kill)
          wait_child(child_pid)
          write_all(status_w, 'failed protocol 0\n')
          close_obj(launch_r); close_obj(status_w)
          os.exit(127)
        end
      end
    end
  end
  close_obj(launch_r)

  write_all(status_w, 'pid ' .. tostring(child_pid) .. '\n')
  local got, how, value, _, wait_eno = wait_child(child_pid)
  if not got then
    write_all(status_w, 'failed reap ' .. tostring(wait_eno or 0) .. '\n')
  elseif how == 'exited' then
    write_all(status_w, 'exited ' .. tostring(tonumber(value) or 0) .. '\n')
  elseif how == 'signaled' or how == 'signalled' then
    write_all(status_w, 'signalled ' .. tostring(tonumber(value) or 0) .. '\n')
  else
    write_all(status_w, 'failed status 0\n')
  end
  close_obj(status_w)
  os.exit(0)
end

local launch_actions = {
  cwd = 'chdir', session = 'setsid', stdio = 'stdio', exec = 'exec', fork = 'fork',
  pipe = 'pipe', handshake = 'exec_handshake', protocol = 'exec_handshake', reap = 'reap', status = 'reap',
}

local function parse_startup_line(line, spec)
  local pid = line:match('^pid (%d+)$')
  if pid then return tonumber(pid) end
  local stage, number = line:match('^failed ([%w_]+) (%d+)$')
  if stage then
    local eno = tonumber(number)
    local action = launch_actions[stage] or 'start'
    local msg = eno and type(nixio.strerror) == 'function' and nixio.strerror(eno) or nil
    return nil, HostError.system('process', action, msg or (action .. ' failed'), nil, eno, { argv = spec.argv })
  end
  return nil, HostError.protocol('process', 'exec_handshake', 'invalid Nixio reaper launch response', {
    argv = spec.argv, payload = line,
  })
end

local function read_startup(status_r, spec)
  local buffer = ''
  while true do
    local chunk, err, eno = read_chunk(status_r, const.buffersize or 256)
    if not chunk then
      local msg = err == 'would_block' and 'launch sentinel unexpectedly would block' or err
      return nil, nil, HostError.system('process', 'exec_handshake', msg, nil, eno, { argv = spec.argv })
    end
    if chunk == '' then
      return nil, nil, HostError.protocol('process', 'exec_handshake', 'Nixio reaper closed before reporting a child pid', {
        argv = spec.argv,
      })
    end
    buffer = buffer .. chunk
    if #buffer > 4096 then
      return nil, nil, HostError.protocol('process', 'exec_handshake', 'Nixio reaper launch response is too large', {
        argv = spec.argv,
      })
    end
    local line, rest = buffer:match('^([^\n]*)\n(.*)$')
    if line then
      local pid, parse_err = parse_startup_line(line, spec)
      return pid, rest, parse_err
    end
  end
end

local HostProcess = {}
HostProcess.__index = HostProcess

function HostProcess:bind_runtime(rt)
  self.runtime = rt
  IOAudit.bind(self, rt)
  if self.status_handle then self.status_handle:bind_runtime(rt) end
  return self
end

function HostProcess:pid() return self._pid end

function HostProcess:wait_op()
  if self.reaped then return Op.always(true) end
  if self.buffer:find('\n', 1, true) then return Op.always(true) end
  if self.status or self.terminal_error then return Sleep.sleep_op(self.poll_interval) end
  if self.status_handle then return self.status_handle:read_ready_op() end
  return Sleep.sleep_op(self.poll_interval)
end

local function parse_terminal(self)
  while true do
    local line, rest = self.buffer:match('^([^\n]*)\n(.*)$')
    if not line then return end
    self.buffer = rest
    local code = line:match('^exited (%d+)$')
    if code then
      code = tonumber(code) or 0
      self.status = { kind = 'exited', code = code, success = code == 0 }
      return
    end
    local number = line:match('^signalled (%d+)$')
    if number then
      number = tonumber(number) or 0
      self.status = {
        kind = 'signalled', signal = number, signal_name = signal_names[number],
        core_dumped = false, success = false,
      }
      return
    end
    local stage, eno_text = line:match('^failed ([%w_]+) (%d+)$')
    if stage then
      local eno = tonumber(eno_text)
      local action = launch_actions[stage] or 'reap'
      local msg = eno and type(nixio.strerror) == 'function' and nixio.strerror(eno) or nil
      self.terminal_error = HostError.system('process', action, msg or (action .. ' failed'), nil, eno, {
        pid = self._pid,
      })
      return
    end
    self.terminal_error = HostError.protocol('process', 'reap', 'invalid Nixio reaper status response', {
      pid = self._pid, payload = line,
    })
    return
  end
end

local function reap_reaper(self)
  if self.reaper_reaped then return true end
  local got, how, value = nixio.waitpid(self.reaper_pid, 'nohang')
  if got == false or got == 0 then
    return nil, HostError.would_block('process', 'reap', { pid = self._pid, reaper_pid = self.reaper_pid })
  end
  if got == nil then
    local msg, eno = error_message('waitpid reaper failed', how, value)
    return nil, HostError.system('process', 'reap', msg, nil, eno, {
      pid = self._pid, reaper_pid = self.reaper_pid,
    })
  end
  self.reaper_reaped = true
  return true
end

function HostProcess:reap()
  if self.reaped then return self.status end
  parse_terminal(self)
  while not self.status and not self.terminal_error do
    if not self.status_handle then
      self.terminal_error = HostError.protocol('process', 'reap', 'Nixio process status pipe is closed', {
        pid = self._pid,
      })
      break
    end
    local chunk, err = self.status_handle:read(const.buffersize or 512)
    if chunk then
      self.buffer = self.buffer .. chunk
      parse_terminal(self)
    elseif HostError.is_would_block(err) then
      return nil, err
    elseif HostError.is_eof(err) then
      self.terminal_error = HostError.protocol('process', 'reap', 'Nixio reaper closed without terminal status', {
        pid = self._pid,
      })
    else
      return nil, HostError.normalise(err, { domain = 'process', action = 'reap', pid = self._pid })
    end
  end

  local reaped, reap_err = reap_reaper(self)
  if not reaped then return nil, reap_err end
  if self.status_handle then
    self.status_handle:close('Nixio process reaped')
    self.status_handle = nil
  end
  if self.terminal_error then return nil, self.terminal_error end
  self.reaped = true
  return self.status
end

function HostProcess:signal(value, target)
  if self.reaped then return nil, HostError.closed('process', 'signal', { pid = self._pid }) end
  local number, signal_err = normalise_signal(value)
  if not number then return nil, signal_err end
  local destination = self._pid
  if target == 'group' then destination = -math.abs(self.group_id or self._pid) end
  local ok, a, b = nixio.kill(destination, number)
  if not ok then
    local msg, eno = error_message('kill failed', a, b)
    return nil, HostError.system('process', 'signal', msg, nil, eno, {
      pid = self._pid, signal = number, target = target,
    })
  end
  return true
end

function HostProcess:close(reason)
  if self.closed then
    IOAudit.closing(self, reason); IOAudit.closed(self, true, nil, reason)
    return true
  end
  self.closed = true
  if self.status_handle then
    self.status_handle:close(reason or 'Nixio process closed')
    self.status_handle = nil
  end
  if not self.reaper_reaped then pcall(nixio.waitpid, self.reaper_pid, 'nohang') end
  IOAudit.closing(self, reason); IOAudit.closed(self, true, nil, reason)
  return true
end

local function support_probe()
  local required = {
    nixio.fork, nixio.waitpid, nixio.exece, nixio.pipe, nixio.open, nixio.dup,
    nixio.kill, nixio.chdir, nixio.getenv, nixio.setsid,
    fs.access, fs.stat, Fd.is_supported,
  }
  for i = 1, #required do if type(required[i]) ~= 'function' then return nil end end
  return Fd.is_supported()
end

function Provider.is_supported()
  local ok = support_probe()
  return not not ok, ok and nil or 'required Nixio process functions unavailable'
end

function Provider.support_reason()
  local ok, reason = Provider.is_supported()
  return ok and nil or reason
end

local function close_many(list)
  for _, obj in ipairs(list or {}) do close_obj(obj) end
end

local function wait_reaper_blocking(pid)
  if not pid then return end
  pcall(nixio.waitpid, pid)
end

local function kill_launched(pid, group_id)
  if not pid then return end
  pcall(nixio.kill, group_id and -math.abs(group_id) or pid, signal_numbers.kill)
end

function Provider.start_process(host, spec)
  if not Provider.is_supported() then
    return nil, nil, HostError.unsupported('host', 'process', { host = host.name })
  end

  local env, env_err = copy_environment(spec)
  if not env then return nil, nil, env_err end
  local exec_path, preflight_err = preflight(spec, env)
  if not exec_path then return nil, nil, preflight_err end

  local inherited = spec.close_fds == false and {} or Fd.open_objects()
  local stdio = { all = {}, opened = {} }
  local parent_fds = {}
  local function add(obj) stdio.all[#stdio.all + 1] = obj end
  local function make_stdio(which, mode)
    stdio[which] = mode
    if mode ~= 'pipe' then return true end
    local r, w, pipe_err = make_pipe('pipe', { stream = which })
    if not r then return nil, pipe_err end
    add(r); add(w)
    if which == 'stdin' then
      stdio.stdin_child = r; parent_fds.stdin = w
    else
      parent_fds[which] = r; stdio[which .. '_child'] = w
    end
    return true
  end

  for _, which in ipairs({ 'stdin', 'stdout', 'stderr' }) do
    local ok, err = make_stdio(which, spec[which] or 'inherit')
    if not ok then close_many(stdio.all); return nil, nil, err end
  end

  local status_r, status_w, status_err = make_pipe('status_pipe')
  if not status_r then close_many(stdio.all); return nil, nil, status_err end
  local blocking_ok, blocking_msg, blocking_eno = set_blocking(status_r, true)
  if not blocking_ok then
    close_many(stdio.all); close_obj(status_r); close_obj(status_w)
    return nil, nil, HostError.system(
      'process', 'exec_handshake', blocking_msg or 'could not make launch sentinel blocking', nil, blocking_eno
    )
  end

  local reaper_pid, a, b = nixio.fork()
  if reaper_pid == nil then
    close_many(stdio.all); close_obj(status_r); close_obj(status_w)
    local msg, eno = error_message('fork reaper failed', a, b)
    return nil, nil, HostError.system('process', 'fork', msg, nil, eno)
  end
  if reaper_pid == 0 then
    reaper_main(spec, exec_path, env, stdio, inherited, status_r, status_w)
    os.exit(127)
  end

  for which, obj in pairs(parent_fds) do
    close_obj(which == 'stdin' and stdio.stdin_child or stdio[which .. '_child'])
  end
  close_obj(status_w)

  local pid, startup_buffer, startup_err = read_startup(status_r, spec)
  if not pid then
    close_obj(status_r); close_many({ parent_fds.stdin, parent_fds.stdout, parent_fds.stderr })
    wait_reaper_blocking(reaper_pid)
    return nil, nil, startup_err
  end

  local status_handle, status_wrap_err = Fd.new(status_r, {
    host = host,
    name = (spec.name or ('process-' .. tostring(pid))) .. ':status',
    nonblocking = true,
  })
  if not status_handle then
    close_many({ parent_fds.stdin, parent_fds.stdout, parent_fds.stderr })
    local group_id = (spec.new_session or spec.process_group == 'new') and pid or nil
    kill_launched(pid, group_id); wait_reaper_blocking(reaper_pid)
    return nil, nil, HostError.normalise(status_wrap_err, { domain = 'process', action = 'wrap_status' })
  end
  status_handle.capabilities.write = false
  status_handle.capabilities.shutdown_write = false

  local endpoints = {}
  for which, obj in pairs(parent_fds) do
    local handle, wrap_err = Fd.new(obj, {
      host = host,
      name = (spec.name or ('process-' .. tostring(pid))) .. ':' .. which,
      nonblocking = true,
    })
    if not handle then
      for _, endpoint in pairs(endpoints) do endpoint:close('process endpoint wrap failed') end
      for other_which, other_obj in pairs(parent_fds) do
        if other_which ~= which and not endpoints[other_which] then close_obj(other_obj) end
      end
      status_handle:close('process endpoint wrap failed')
      local group_id = (spec.new_session or spec.process_group == 'new') and pid or nil
      kill_launched(pid, group_id); wait_reaper_blocking(reaper_pid)
      return nil, nil, HostError.normalise(wrap_err, { domain = 'process', action = 'wrap_' .. which })
    end
    if which == 'stdin' then
      handle.capabilities.read = false; handle.capabilities.shutdown_read = false
    else
      handle.capabilities.write = false; handle.capabilities.shutdown_write = false
    end
    endpoints[which] = handle
  end

  local process = setmetatable({
    name = spec.name or ('process-' .. tostring(pid)),
    _pid = pid,
    reaper_pid = reaper_pid,
    group_id = (spec.new_session or spec.process_group == 'new') and pid or nil,
    poll_interval = spec.poll_interval or 0.025,
    status_handle = status_handle,
    buffer = startup_buffer or '',
    status = nil,
    terminal_error = nil,
    reaper_reaped = false,
    reaped = false,
    closed = false,
  }, HostProcess)
  IOAudit.created(process, { kind = 'process_handle' })
  IOAudit.transfer(status_handle, process, { kind = 'host_handle', role = 'process_status' })
  return process, endpoints
end

Provider._test = {
  preflight = preflight,
  copy_environment = copy_environment,
  parse_startup_line = parse_startup_line,
  close_inherited = close_inherited,
}

return Provider
