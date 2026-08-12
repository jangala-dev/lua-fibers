-- Structured child-process facility.
--
-- Command is a captured, reusable specification. launch_op selects and admits a fresh
-- Process at synchronisation time; its committed driver performs the irreversible
-- host launch afterwards. start is the direct launch-plus-handshake convenience.
-- Process is one running Lifetime under custody above an interchangeable host-process
-- provider. Task, Scope and Process are capability views over that Lifetime;
-- observations remain ordinary options and Closure resolves its private custody.

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local CommandModule = require('fibers.process.command')
local IOError = require('fibers.io.error')
local FlowErrors = require('fibers.resource.flow.errors')
local Acquired = require('fibers.io.internal.acquired')
local Completion = require('fibers.resource.completion')
local IO = require('fibers.io.facility')
local HostProcess = require('fibers.io.process')
local IOAudit = require('fibers.internal.io_audit')
local Task = require('fibers.task')
local Protected = require('fibers.protected')
local Sleep = require('fibers.sleep')
local Exit = Task.Exit
local perform = require('fibers.perform')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Cell = require('fibers.resource.cell')
local Mailbox = require('fibers.mailbox')

local ENDPOINTS = { 'stdin', 'stdout', 'stderr' }
local OUTPUTS = { 'stdout', 'stderr' }

local function process_label(proc)
  return Label.describe(proc, proc._fibers_id or 'process')
end

local Module = {}
local Command = CommandModule.Command
local Process = {}
Process.__index = Process

local copy_table = CommandModule.copy_table
local redirect_stream = CommandModule.redirect_stream

Module.command = CommandModule.command
Module.shell = CommandModule.shell
Module.redirect = CommandModule.redirect
local function close_host_process(value, reason)
  return IO.close_value('process', value, reason)
end

local function close_process_endpoint(value, reason)
  return IO.close_value('process_pipe', value, reason)
end

function Process:lifetime()
  return self._lifetime
end

local function launch_op(proc, want)
  return proc._state:select_op(function(state)
    if state.kind == 'created' or state.kind == 'launching' then return end
    local succeeded = state.kind ~= 'failed'
    if want == nil then return succeeded and Op.always(proc) or Op.always(nil, state.error) end
    if want ~= succeeded then return Op.never() end
    return Op.always(succeeded and proc or state.error)
  end)
end

local function after_launch(proc, field)
  return launch_op(proc):map(function(launched, err)
    if launched == nil then return nil, err end
    return field == '_pid' and proc._pid or proc._streams[field]
  end)
end

function Process:pid_op()
  return after_launch(self, '_pid')
end

function Process:argv() return self._command:argv() end

function Process:stdin_op()
  return after_launch(self, 'stdin')
end
function Process:stdout_op()
  return after_launch(self, 'stdout')
end
function Process:stderr_op()
  return after_launch(self, 'stderr')
end

function Process:launch_succeeded_op() return launch_op(self, true) end
function Process:launch_failed_op() return launch_op(self, false) end
function Process:launch_result_op() return launch_op(self) end

function Process:result_op()
  return self._exit_completion:result_op()
end

function Process:request_close_op(reason)
  return self._lifetime:request_close_op(reason or 'process closed'):map(function(_, recorded)
    return true, recorded
  end)
end

function Process:closed_op()
  return IO.closed_after_driver_op(self._driver)
end

local function process_not_running(proc, action, state)
  return IOError.closed('process', action, {
    pid = proc._pid,
    state = state and state.kind,
  })
end

local SignalRequest = {}
SignalRequest.__index = SignalRequest

function SignalRequest:result_op()
  return self._completion:result_op()
end

function Process:submit_signal_op(signal, target)
  target = target or self._command._spec.shutdown.target or 'process'
  local proc = self
  return Op.guard(function()
    local request = setmetatable({
      kind = 'process_signal_request',
      signal = signal,
      target = target,
      _completion = Completion.new(),
    }, SignalRequest)
    Label.child(request._completion, request, 'result')

    return proc._state:read_op():and_then(Op.guard(function(state)
      if state.kind ~= 'running' and state.kind ~= 'closing' then
        return Op.always(nil, process_not_running(proc, 'signal', state))
      end
      return proc._control_tx:send_op(request):map(function(sent, err)
        if not sent then return nil, err end
        return request
      end)
    end))
  end)
end

function Process:submit_terminate_op()
  return self:submit_signal_op(self._command._spec.shutdown.signal)
end

function Process:submit_kill_op()
  return self:submit_signal_op(self._command._spec.shutdown.kill_signal)
end

local function await_signal_submission(proc, submission)
  local request, err = perform(submission)
  if not request then return nil, err end
  return request:result()
end

function Process:signal(signal, target)
  return await_signal_submission(self, self:submit_signal_op(signal, target))
end

function Process:terminate()
  return await_signal_submission(self, self:submit_terminate_op())
end

function Process:kill()
  return await_signal_submission(self, self:submit_kill_op())
end

function Process:communicate(opts)
  opts = copy_table(opts)
  local limits = { stdout = opts.stdout_limit or 4 * 1024 * 1024, stderr = opts.stderr_limit or 4 * 1024 * 1024 }
  for _, name in ipairs(OUTPUTS) do
    if type(limits[name]) ~= 'number' or limits[name] < 0 then error(name .. '_limit must be a non-negative number', 2) end
  end

  -- Communicate is deliberately a direct, committed multi-phase procedure.
  -- Input must reach the external child before exit can be observed. Host Streams
  -- continue to drain into their Flows while input is written, so the concurrent
  -- reads below cannot deadlock on ordinary pipe buffers.
  local rt = Runtime.current()
  local scope = Runtime.current_scope()
  if not rt or not scope then
    error('Process:communicate requires a current runtime scope', 2)
  end
  if self._communicating then
    return nil,
      IOError.invalid_argument('process', 'communicate', {
        message = 'communicate may be used only once for a Process',
      })
  end
  self._communicating = true

  local function fail(reason, err)
    Protected.pcall(function()
      return self:close(reason)
    end)
    return nil, err
  end

  local stdin_stream = self._streams.stdin
  if not stdin_stream then
    if opts.input ~= nil and opts.input ~= '' then
      return fail(
        'communicate input unavailable',
        IOError.invalid_argument('process', 'communicate', {
          message = 'process stdin is not piped',
        })
      )
    end
  else
    if opts.input ~= nil and opts.input ~= '' then
      if type(opts.input) ~= 'string' then
        return fail(
          'invalid communicate input',
          IOError.invalid_argument('process', 'communicate', {
            message = 'communicate input must be a string',
          })
        )
      end
      local written, write_err = stdin_stream:write(opts.input)
      if not written then
        return fail('communicate input failed', write_err)
      end
      local flushed, flush_err = stdin_stream:flush()
      if not flushed then
        return fail('communicate input failed', flush_err)
      end
    end
    local shut, shut_err = stdin_stream:shutdown_write('communicate input complete')
    if not shut then
      return fail('communicate input shutdown failed', shut_err)
    end
    local closed, close_err = stdin_stream:closed()
    if not closed then
      return fail('communicate input close failed', close_err)
    end
  end

  local streams = { stdout = self._streams.stdout, stderr = self._streams.stderr }
  if streams.stderr == streams.stdout then streams.stderr = nil end
  local spawn_ops = {}
  for _, name in ipairs(OUTPUTS) do
    local output, stream = name, streams[name]
    spawn_ops[name] = stream and scope:spawn_op(function()
      return stream:read_all({ max = limits[output] })
    end, { label = process_label(self) .. ':communicate-' .. output }) or Op.always(nil)
  end
  local tasks = perform(Op.named_each(spawn_ops))

  local complete, alternatives = { status = self:result_op() }, {}
  local function failure_op(task)
    return task:body_result_op():and_then(Op.guard(function(exit)
      local _, task_err = Exit.unwrap(exit)
      return task_err ~= nil and Op.always(task_err) or Op.never()
    end))
  end
  for _, name in ipairs(OUTPUTS) do
    local task = tasks[name]
    complete[name] = task and task:body_result_op() or Op.always(nil)
    if task then alternatives[name .. '_failed'] = failure_op(task) end
  end
  alternatives.complete = Op.named_each(complete)

  local event, parts = rt:_perform_current(Op.named_choice(alternatives), nil, true)
  if event ~= 'complete' then return fail('communicate ' .. event:gsub('_failed$', '') .. ' failed', parts) end

  local result = { status = parts.status }
  for _, name in ipairs(OUTPUTS) do
    local task = tasks[name]
    if task then
      local value, err = Exit.unwrap(parts[name])
      if value == nil and err ~= nil then return fail('communicate ' .. name .. ' failed', err) end
      result[name] = value
    end
  end
  local status_row = parts._rows and parts._rows.status
  if status_row and status_row.n and status_row.n >= 2 and status_row[1] == nil then
    return fail('communicate process result failed', status_row[2])
  end
  return result
end


local function stream_bridge(source, destination, opts)
  opts = opts or {}
  local chunk_size = opts.chunk_size or 4096
  while true do
    local bytes, err = source:read_some(chunk_size)
    if not bytes then
      if err == FlowErrors.EOF or err == FlowErrors.CLOSED or err == FlowErrors.RETIRED then
        break
      end
      return nil, err
    end
    local written, write_err = destination:write(bytes)
    if not written then
      return nil, write_err
    end
  end
  if opts.flush ~= false then
    local ok, err = destination:flush()
    if not ok then
      return nil, err
    end
  end
  if opts.close_destination then
    destination:shutdown_write('process redirect complete')
  end
  return true
end

local function endpoint_opts(spec, which)
  local configured = spec[which]
  local stream, redirect = redirect_stream(configured)
  if stream then
    return 'pipe', stream, redirect
  end
  return configured, nil, nil
end

local function parent_stream_op(scope, handle, which, opts, label)
  local read = which == 'stdout' or which == 'stderr'
  return IO.handle_stream_op(scope, handle, {
    label = label .. ':' .. which, read = read, write = not read,
  }, opts)
end

local function publish_state(rt, proc, state)
  return IO.masked_perform(rt, proc._state:write_op(state))
end

local function publish_launch_failure(rt, proc, err)
  Protected.pcall(function()
    local seen = {}
    for _, stream in pairs(proc._pipe_streams) do
      if not seen[stream] then stream:abort(err); seen[stream] = true end
    end
    if proc._host_process then proc._host_process:close(err) end
  end)
  publish_state(rt, proc, { kind = 'failed', error = err })
  IO.masked_perform(rt, proc._exit_completion:publish_failure_op(err))
end

local function publish_exit(rt, proc, status)
  publish_state(rt, proc, { kind = 'exited', status = status, pid = proc._pid })
  IO.masked_perform(rt, proc._exit_completion:publish_success_op(status))
end

local function publish_signal_result(rt, request, ok, err)
  if ok then
    IO.masked_perform(rt, request._completion:publish_success_op(true))
  else
    IO.masked_perform(rt, request._completion:publish_failure_op(err))
  end
end

local function service_signal_request(rt, proc, request)
  local handle = proc._host_process
  if not handle or type(handle.signal) ~= 'function' then
    local err = IOError.unsupported('host', 'process_signal', { pid = proc._pid })
    publish_signal_result(rt, request, false, err)
    return nil, err
  end

  local called, ok, err = Protected.pcall(handle.signal, handle, request.signal, request.target)
  if not called then
    err = IOError.protocol('process', 'signal', 'host process signal raised', {
      pid = proc._pid, signal = request.signal, target = request.target, cause = ok,
    })
    publish_signal_result(rt, request, false, err)
    return nil, err
  end
  if not ok then
    err = IOError.normalise(err, {
      domain = 'process', action = 'signal', pid = proc._pid,
      signal = request.signal, target = request.target,
    })
    publish_signal_result(rt, request, false, err)
    return nil, err
  end

  publish_signal_result(rt, request, true)
  return true
end

local function running_event_op(proc, deadline, include_close)
  local alternatives = {
    exit = proc._host_process:exit_op(),
    signal = proc._control_rx:recv_op(),
  }
  if include_close then
    alternatives.close = proc._lifetime:close_requested_op()
  end
  if deadline ~= nil then
    alternatives.timeout = Sleep.sleep_until_op(deadline):map(function() return true end)
  end
  return Op.named_choice(alternatives)
end

local function wait_exit_until(proc, rt, deadline)
  while true do
    local event, value, err = perform(running_event_op(proc, deadline))
    if event == 'exit' then return value, err end
    if event == 'timeout' then return nil, 'timeout' end
    if event == 'signal' then
      if value ~= nil then service_signal_request(rt, proc, value) end
    end
    -- A close event is already in force while this helper is used; keep waiting
    -- for exit while still servicing explicitly submitted signal requests.
  end
end

local function finish_close(proc, reason)
  local errors = {}
  local function record_close_error(label, fn)
    local ok, a, b = Protected.pcall(fn)
    if not ok or not a then
      errors[#errors + 1] = { stage = label, error = ok and b or a }
    end
  end
  local seen = {}
  for _, which in ipairs(ENDPOINTS) do
    local stream = proc._pipe_streams[which] or proc._streams[which]
    if stream and not seen[stream] then
      seen[stream] = true
      record_close_error(which, function() return stream:abort(reason) end)
    end
  end
  record_close_error('host_process', function()
    return proc._host_process and proc._host_process:close(reason) or true
  end)
  if #errors > 0 then
    return nil,
      IOError.protocol('process', 'close', 'one or more process resources failed to close', {
        pid = proc._pid,
        errors = errors,
      })
  end
  return true
end

local function supervise(proc, driver_scope, opts, acquired)
  local rt = Runtime.current()
  local spec = proc._command:spec()
  local stdin_mode, stdin_source, stdin_redirect = endpoint_opts(spec, 'stdin')
  local stdout_mode, stdout_destination, stdout_redirect = endpoint_opts(spec, 'stdout')
  local stderr_mode, stderr_destination, stderr_redirect = endpoint_opts(spec, 'stderr')
  spec.stdin, spec.stdout, spec.stderr = stdin_mode, stdout_mode, stderr_mode
  spec.runtime = rt
  spec.label = process_label(proc)

  publish_state(rt, proc, { kind = 'launching' })
  local host = opts.host or rt.host
  local host_process, endpoints, start_err = HostProcess.start(host, spec)
  if not host_process then
    publish_launch_failure(
      rt,
      proc,
      IOError.normalise(start_err or endpoints, {
        domain = 'process',
        action = 'start',
        argv = spec.argv,
      })
    )
    return
  end
  endpoints = endpoints or {}

  acquired:hold('process', host_process, close_host_process)
  for _, which in ipairs(ENDPOINTS) do
    if endpoints[which] then acquired:hold(which, endpoints[which], close_process_endpoint) end
  end

  if type(host_process.bind_runtime) == 'function' then
    host_process:bind_runtime(rt)
  else
    IOAudit.bind(host_process, rt)
  end
  proc._host_process = host_process
  proc._pid = type(host_process.pid) == 'function' and host_process:pid() or host_process.pid
  IOAudit.transfer(host_process, proc, { kind = 'process_handle', role = 'process' })
  acquired:release('process', host_process)

  local exit_opened, exit_open_err = perform(host_process:open_exit_op(driver_scope))
  if not exit_opened then
    publish_launch_failure(
      rt,
      proc,
      IOError.normalise(exit_open_err, {
        domain = 'process',
        action = 'open_exit_completion',
        pid = proc._pid,
      })
    )
    return
  end

  local stream_ops = {}
  for _, which in ipairs(ENDPOINTS) do
    local handle = endpoints[which]
    if handle then
      if type(handle.bind_runtime) == 'function' then handle:bind_runtime(rt) end
      stream_ops[which] = parent_stream_op(driver_scope, handle, which, opts, process_label(proc))
    end
  end
  local ok, streams = Protected.pcall(function()
    return IO.masked_perform(rt, Op.named_together(stream_ops))
  end)
  if not ok then
    publish_launch_failure(rt, proc, IOError.normalise(streams, {
      domain = 'process', action = 'open_endpoints', pid = proc._pid,
    }))
    return
  end
  proc._pipe_streams = streams
  for _, which in ipairs(ENDPOINTS) do
    if endpoints[which] then acquired:release(which, endpoints[which]) end
  end

  if stdin_source then
    driver_scope:spawn(function()
      return stream_bridge(stdin_source, proc._pipe_streams.stdin, {
        flush = stdin_redirect.flush,
        close_destination = true,
      })
    end, { label = process_label(proc) .. ':stdin-bridge' })
    proc._streams.stdin = nil
  else
    proc._streams.stdin = proc._pipe_streams.stdin
  end
  if stdout_destination then
    driver_scope:spawn(function()
      return stream_bridge(proc._pipe_streams.stdout, stdout_destination, {
        flush = stdout_redirect.flush,
        close_destination = stdout_redirect.close,
      })
    end, { label = process_label(proc) .. ':stdout-bridge' })
    proc._streams.stdout = nil
  else
    proc._streams.stdout = proc._pipe_streams.stdout
  end
  if stderr_destination then
    driver_scope:spawn(function()
      return stream_bridge(proc._pipe_streams.stderr, stderr_destination, {
        flush = stderr_redirect.flush,
        close_destination = stderr_redirect.close,
      })
    end, { label = process_label(proc) .. ':stderr-bridge' })
    proc._streams.stderr = nil
  elseif stderr_mode == 'stdout' then
    proc._streams.stderr = proc._streams.stdout
  else
    proc._streams.stderr = proc._pipe_streams.stderr
  end

  if type(host_process.start) == 'function' then
    local ok, err = host_process:start()
    if not ok then
      publish_launch_failure(
        rt,
        proc,
        IOError.normalise(err, {
          domain = 'process',
          action = 'start_driver',
          pid = proc._pid,
        })
      )
      return
    end
  end

  publish_state(rt, proc, { kind = 'running', pid = proc._pid })

  local status, close_error
  local close_requested = proc._lifetime:_close_requested()
  while not close_requested and not status do
    local event, value, err = perform(running_event_op(proc, nil, true))
    if event == 'exit' then
      status = value
      if not status then
        IO.masked_perform(rt, proc._exit_completion:publish_failure_op(err))
      end
    elseif event == 'signal' then
      if value ~= nil then service_signal_request(rt, proc, value) end
    elseif event == 'close' then
      close_requested = true
    end
    close_requested = close_requested or proc._lifetime:_close_requested()
  end

  close_requested = proc._lifetime:_close_requested()
  if not status and close_requested then
    local _, reason = proc._lifetime:_close_requested()
    reason = reason or 'process closed'
    publish_state(rt, proc, { kind = 'closing', pid = proc._pid, reason = reason })
    if proc._pipe_streams.stdin then
      Protected.pcall(function()
        proc._pipe_streams.stdin:abort(reason)
      end)
    end
    local signal_ok, signal_err = host_process:signal(spec.shutdown.signal, spec.shutdown.target)
    if not signal_ok and not IOError.is(signal_err, 'closed') then
      close_error = IOError.normalise(signal_err, {
        domain = 'process', action = 'terminate', pid = proc._pid,
      })
    end
    local deadline = rt:now() + spec.shutdown.grace
    local exit_err
    status, exit_err = wait_exit_until(proc, rt, deadline)
    if not status and exit_err == 'timeout' then
      host_process:signal(spec.shutdown.kill_signal, spec.shutdown.target)
      status, exit_err = wait_exit_until(proc, rt, nil)
    end
    if not status then
      IO.masked_perform(rt, proc._exit_completion:publish_failure_op(exit_err))
      close_error = close_error or exit_err
    end
  end

  if status then
    publish_exit(rt, proc, status)
  end

  close_requested = proc._lifetime:_close_requested()
  if not close_requested then perform(proc._lifetime:close_requested_op()) end
  local _, reason = proc._lifetime:_close_requested()
  reason = reason or 'process closed'
  publish_state(rt, proc, { kind = 'closing', pid = proc._pid, reason = reason, status = status })
  local closed, close_err = finish_close(proc, reason)
  close_error = close_error or close_err
  publish_state(rt, proc, {
    kind = 'closed', pid = proc._pid, status = status,
    error = close_error,
  })
end

local function driver_body(proc, driver_scope, opts)
  local acquired = Acquired.new()
  local ok, err = Protected.pcall(supervise, proc, driver_scope, opts, acquired)
  local cleanup_ok, cleanup_err = acquired:close(ok and 'process setup completed' or err)
  if ok and not cleanup_ok then
    ok, err = false, cleanup_err
  end
  if ok then
    local state = proc._state._location.value
    if state.kind == 'closed' and state.error then return nil, state.error end
    return true
  end
  local rt = Runtime.current()
  local failure = IOError.is(err) and err
    or IO.protocol_error('process', 'supervisor', err, {
      pid = proc._pid,
      argv = proc._command._spec.argv,
    })
  local state = proc._state._location.value
  if state.kind == 'created' or state.kind == 'launching' then
    publish_launch_failure(rt, proc, failure)
  elseif proc._exit_completion:_is_pending() then
    IO.masked_perform(rt, proc._exit_completion:publish_failure_op(failure))
  end
  state = proc._state._location.value
  if state.kind ~= 'failed' then
    publish_state(rt, proc, { kind = 'closed', pid = proc._pid, status = state.status, error = failure })
  end
  return nil, failure
end

function Command:launch_op(opts)
  opts = copy_table(opts)
  local command = self
  local spec = command._spec
  if
    spec.shutdown.target == 'group'
    and spec.process_group ~= 'new'
    and type(spec.process_group) ~= 'number'
  then
    error("group shutdown requires process_group = 'new' or a numeric group", 2)
  end

  -- Custody comes from the surrounding fiber context and is resolved when the
  -- option is constructed. The Process itself is fresh per guard activation.
  local scope = IO.current_scope(opts, 'Command:launch_op')
  local parent_scope = IO.require_scope(scope, 'Command:launch_op')

  -- A launch option constructs a fresh Process Lifetime for each synchronisation
  -- attempt. The guard is speculative and pure: no host action occurs until the
  -- Process root and its private custody have committed and its Task view starts.
  return Op.guard(function()
    local control_tx, control_rx = Mailbox.new(0)
    local proc = Label.attach(Label.identity(setmetatable({
      kind = 'process',
      _command = command,
      _state = Cell._trusted({ kind = 'created' }),
      _exit_completion = Completion.new(),
      _control_tx = control_tx,
      _control_rx = control_rx,
      _communicating = false,
      _host_process = nil,
      _streams = {},
      _pipe_streams = {},
      _pid = nil,
    }, Process), 'process'), opts.label)
    Label.child(proc._state, proc, 'state')
    Label.child(proc._exit_completion, proc, 'exit')
    control_tx:label(process_label(proc) .. ':control')
    local admitted = parent_scope:_drive_op(proc, {
      label = opts.label,
      role = 'process',
      closure = IO._closeable_closure(proc, {
        name = 'process', reason = 'scope closure', request = 'request_close_op',
        finish_result = 'process closure failed',
      }),
      run = function(driver_scope) return driver_body(proc, driver_scope, opts) end,
    })
    return admitted
  end)
end


function Command:start(opts)
  local proc, launch_err = self:launch(opts)
  if not proc then
    return nil, launch_err
  end
  local launched, err = proc:launch_result()
  if not launched then
    -- A launch failure path has already closed all partial host resources and
    -- published completed closure. Waiting here preserves that postcondition.
    proc:closed()
    return nil, err
  end
  return proc
end

function Process:close(reason)
  local ok, err = self:request_close(reason)
  if not ok then
    return nil, err
  end
  return self:closed()
end
function Module.succeeded(status)
  return type(status) == 'table' and status.kind == 'exited' and status.code == 0
end

function Module.describe_status(status)
  if type(status) ~= 'table' then
    return tostring(status)
  end
  if status.kind == 'exited' then
    return 'exited with code ' .. tostring(status.code)
  end
  if status.kind == 'signalled' then
    return 'terminated by signal ' .. tostring(status.signal_name or status.signal)
  end
  return tostring(status.kind or 'process status')
end

Module.Command = Command
Module.Process = Process
Module.Error = IOError

Direct.install(Command, { 'launch' })
Direct.install(SignalRequest, { 'result' })
Direct.install(Process, { 'pid', 'stdin', 'stdout', 'stderr', 'launch_succeeded', 'launch_failed', 'launch_result', 'result', 'submit_signal', 'submit_terminate', 'submit_kill', 'request_close', 'closed' })

return Module
