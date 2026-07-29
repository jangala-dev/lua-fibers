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
local Cell = require('fibers.resource.cell')
local StateMachine = require('fibers.resource.machine')
local CommandModule = require('fibers.process.command')
local IOError = require('fibers.io.error')
local FlowErrors = require('fibers.resource.flow.errors')
local HostHold = require('fibers.io.internal.host_hold')
local Completion = require('fibers.resource.completion')
local IO = require('fibers.io.facility')
local HostProcess = require('fibers.io.process')
local IOAudit = require('fibers.internal.io_audit')
local Lifetime = require('fibers.lifetime')
local Task = require('fibers.task')
local Scope = require('fibers.scope')
local Closure = require('fibers.closure')
local Protected = require('fibers.protected')
local Sleep = require('fibers.sleep')
local Exit = Task.Exit
local perform = require('fibers.perform')

local Lifecycle = {}
Lifecycle.__index = Lifecycle

local Ready = StateMachine.Ready

local request_close = StateMachine.isolated_update('process.request_close', function(current, reason)
  if current.requested then
    return Ready.same(true, current.reason)
  end
  return Ready.write({ requested = true, reason = reason or 'process closed' }, true, reason)
end)

local function wait_for(cell, predicate)
  return Cell.match_op(cell, predicate)
end

function Lifecycle.new(name)
  return setmetatable({
    name = name,
    state = Cell.new({ kind = 'created' }, name .. ':state'),
    close_request = StateMachine.new({ requested = false, reason = nil }, name .. ':close-request'),
  }, Lifecycle)
end

function Lifecycle:state_op()
  return self.state:read_op()
end

function Lifecycle:state_value()
  return self.state.value
end

function Lifecycle:set_state_op(value)
  return self.state:write_op(value)
end

function Lifecycle:request_close_op(reason)
  return self.close_request:transition_op(request_close, reason)
end

function Lifecycle:close_requested_op()
  return wait_for(self.close_request, function(value)
    if value.requested then
      return true, value.reason
    end
    return false
  end)
end

function Lifecycle:is_close_requested()
  return self.close_request.value.requested == true
end

function Lifecycle:close_reason()
  return self.close_request.value.reason
end

local Module = {}
local Command = CommandModule.Command
local Process = {}
Process.__index = Process

local copy_table = CommandModule.copy_table
local copy_list = CommandModule.copy_list
local copy_spec = CommandModule.copy_spec
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

local function process_closure(proc)
  return Closure.request_then_wait(function(_ctx, _record, reason)
    return proc:request_close_op(reason or 'scope closure')
  end, function()
    return proc:closed_op()
  end, {
    name = 'process',
    finish_result = Closure.require_ok('process closure failed'),
  })
end

function Process:lifetime()
  return self._lifetime
end

function Process:pid()
  return self._pid
end

function Process:argv()
  return copy_list(self.command._spec.argv)
end

function Process:state_value()
  return self.lifecycle:state_value()
end

function Process:stdin()
  return self.stdin_stream
end
function Process:stdout()
  return self.stdout_stream
end
function Process:stderr()
  return self.stderr_stream
end

function Process:launch_succeeded_op()
  return self.launch_completion:success_op()
end

function Process:launch_failed_op()
  return self.launch_completion:failure_op()
end

function Process:launch_result_op()
  return self.launch_completion:result_op()
end

function Process:result_op()
  return self.exit_completion:result_op()
end

function Process:request_close_op(reason)
  return self.lifecycle:request_close_op(reason)
end

function Process:closed_op()
  return IO.closed_after_driver_op(self._task, self.closed_completion:result_op(), {
    require_returned = true,
  })
end

local function process_not_running(proc, action)
  local state = proc:state_value()
  return IOError.closed('process', action, {
    pid = proc._pid,
    state = state and state.kind,
  })
end

function Process:signal_op(signal, target)
  target = target or self.command._spec.shutdown.target or 'process'
  return self.lifecycle:state_op():and_then(function(state)
    if state.kind ~= 'running' and state.kind ~= 'closing' then
      return Op.always(nil, process_not_running(self, 'signal'))
    end
    return Op.always(true):wrap(function()
      local handle = self.host_process
      if not handle or type(handle.signal) ~= 'function' then
        return nil, IOError.unsupported('host', 'process_signal', { pid = self._pid })
      end
      local ok, err = handle:signal(signal, target)
      if not ok then
        return nil,
          IOError.normalise(err, {
            domain = 'process',
            action = 'signal',
            pid = self._pid,
            signal = signal,
            target = target,
          })
      end
      return true
    end)
  end)
end

function Process:terminate_op()
  return self:signal_op(self.command._spec.shutdown.signal)
end
function Process:kill_op()
  return self:signal_op(self.command._spec.shutdown.kill_signal)
end

function Process:communicate(opts)
  opts = copy_table(opts)
  local stdout_limit = opts.stdout_limit or 4 * 1024 * 1024
  local stderr_limit = opts.stderr_limit or 4 * 1024 * 1024
  if type(stdout_limit) ~= 'number' or stdout_limit < 0 then
    error('stdout_limit must be a non-negative number', 2)
  end
  if type(stderr_limit) ~= 'number' or stderr_limit < 0 then
    error('stderr_limit must be a non-negative number', 2)
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

  local stdin_stream = self:stdin()
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

  local stdout_stream = self:stdout()
  local stderr_stream = self:stderr()
  if stderr_stream == stdout_stream then
    stderr_stream = nil
  end
  local tasks = perform(Op.named_each({
    stdout = stdout_stream and scope:spawn_op(function()
      return stdout_stream:read_all({ max = stdout_limit })
    end, { name = self.name .. ':communicate-stdout' }) or Op.always(nil),
    stderr = stderr_stream and scope:spawn_op(function()
      return stderr_stream:read_all({ max = stderr_limit })
    end, { name = self.name .. ':communicate-stderr' }) or Op.always(nil),
  }))
  local stdout_task, stderr_task = tasks.stdout, tasks.stderr

  local complete_op = Op.named_each({
    stdout = stdout_task and stdout_task:body_result_op() or Op.always(nil),
    stderr = stderr_task and stderr_task:body_result_op() or Op.always(nil),
    status = self:result_op(),
  })

  local alternatives = { complete = complete_op }
  local function failure_op(task)
    return task:body_result_op():and_then(function(exit)
      local _, task_err = Exit.unwrap(exit)
      if task_err ~= nil then
        return Op.always(task_err)
      end
      return Op.never()
    end)
  end
  if stdout_task then
    alternatives.stdout_failed = failure_op(stdout_task)
  end
  if stderr_task then
    alternatives.stderr_failed = failure_op(stderr_task)
  end

  local event, value = rt:_perform_current(Op.named_choice(alternatives), nil, true)
  if event == 'stdout_failed' then
    return fail('communicate stdout failed', value)
  elseif event == 'stderr_failed' then
    return fail('communicate stderr failed', value)
  end

  local parts = value
  local stdout, stdout_err
  if stdout_task then
    stdout, stdout_err = Exit.unwrap(parts.stdout)
  end
  if stdout_task and stdout == nil and stdout_err ~= nil then
    return fail('communicate stdout failed', stdout_err)
  end
  local stderr, stderr_err
  if stderr_task then
    stderr, stderr_err = Exit.unwrap(parts.stderr)
  end
  if stderr_task and stderr == nil and stderr_err ~= nil then
    return fail('communicate stderr failed', stderr_err)
  end
  local status_row = parts._rows and parts._rows.status
  if status_row and status_row.n and status_row.n >= 2 and status_row[1] == nil then
    return fail('communicate process result failed', status_row[2])
  end
  return { status = parts.status, stdout = stdout, stderr = stderr }
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

local function open_parent_stream(rt, scope, handle, which, opts)
  local read = which == 'stdout' or which == 'stderr'
  return IO.open_handle_stream(rt, scope, handle, {
    name = opts.name .. ':' .. which,
    read = read,
    write = not read,
    capacity = opts.capacity,
    read_capacity = opts.read_capacity,
    write_capacity = opts.write_capacity,
    chunk_size = opts.chunk_size,
    read_chunk_size = opts.read_chunk_size,
    write_chunk_size = opts.write_chunk_size,
  })
end

local function publish_state(rt, proc, state)
  return IO.masked_perform(rt, proc.lifecycle:set_state_op(state))
end

local function publish_launch_failure(rt, proc, err)
  Protected.pcall(function()
    if proc.stdin_pipe_stream then
      proc.stdin_pipe_stream:abort(err)
    end
    if proc.stdout_pipe_stream then
      proc.stdout_pipe_stream:abort(err)
    end
    if proc.stderr_pipe_stream and proc.stderr_pipe_stream ~= proc.stdout_pipe_stream then
      proc.stderr_pipe_stream:abort(err)
    end
    if proc.host_hold then
      proc.host_hold:close(err)
    end
    if proc.host_process then
      proc.host_process:close(err)
    end
  end)
  publish_state(rt, proc, { kind = 'failed', error = err })
  IO.masked_perform(rt, proc.launch_completion:publish_failure_op(err))
  IO.masked_perform(rt, proc.exit_completion:publish_failure_op(err))
  IO.masked_perform(rt, proc.closed_completion:publish_success_op(true))
end

local function publish_exit(rt, proc, status)
  proc._status = status
  publish_state(rt, proc, { kind = 'exited', status = status, pid = proc._pid })
  IO.masked_perform(rt, proc.exit_completion:publish_success_op(status))
end

local function wait_exit_until(proc, deadline)
  return perform(proc.host_process:exit_op():or_else(Sleep.sleep_until_op(deadline):map(function()
    return nil, 'timeout'
  end)))
end

local function close_stream(stream, reason, abort)
  if not stream then
    return true
  end
  if abort then
    return stream:abort(reason)
  end
  return stream:close(reason)
end

local function finish_close(proc, reason)
  local errors = {}
  local function record_close_error(label, fn)
    local ok, a, b = Protected.pcall(fn)
    if not ok or not a then
      errors[#errors + 1] = { stage = label, error = ok and b or a }
    end
  end
  record_close_error('stdin', function()
    return close_stream(proc.stdin_pipe_stream or proc.stdin_stream, reason, true)
  end)
  record_close_error('stdout', function()
    return close_stream(proc.stdout_pipe_stream or proc.stdout_stream, reason, true)
  end)
  local stderr_to_close = proc.stderr_pipe_stream or proc.stderr_stream
  local stdout_to_close = proc.stdout_pipe_stream or proc.stdout_stream
  if stderr_to_close and stderr_to_close ~= stdout_to_close then
    record_close_error('stderr', function()
      return close_stream(stderr_to_close, reason, true)
    end)
  end
  record_close_error('host_process', function()
    return proc.host_process and proc.host_process:close(reason) or true
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

local function supervise(proc, driver_scope, opts)
  local rt = Runtime.current()
  local host_hold = proc.host_hold
  local spec = copy_spec(proc.command._spec)
  local stdin_mode, stdin_source, stdin_redirect = endpoint_opts(spec, 'stdin')
  local stdout_mode, stdout_destination, stdout_redirect = endpoint_opts(spec, 'stdout')
  local stderr_mode, stderr_destination, stderr_redirect = endpoint_opts(spec, 'stderr')
  spec.stdin, spec.stdout, spec.stderr = stdin_mode, stdout_mode, stderr_mode
  spec.runtime = rt
  spec.name = proc.name

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

  local entries = {
    { name = 'process', value = host_process, close = close_host_process },
  }
  for _, which in ipairs({ 'stdin', 'stdout', 'stderr' }) do
    if endpoints[which] then
      entries[#entries + 1] = { name = which, value = endpoints[which], close = close_process_endpoint }
    end
  end
  local held, hold_err = host_hold:hold_many(entries)
  if not held then
    publish_launch_failure(rt, proc, hold_err)
    return
  end

  if type(host_process.bind_runtime) == 'function' then
    host_process:bind_runtime(rt)
  else
    IOAudit.bind(host_process, rt)
  end
  proc.host_process = host_process
  proc._pid = type(host_process.pid) == 'function' and host_process:pid() or host_process.pid
  IOAudit.transfer(host_process, proc, { kind = 'process_handle', role = 'process' })
  host_hold:release('process', host_process)

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

  for _, which in ipairs({ 'stdin', 'stdout', 'stderr' }) do
    local handle = endpoints[which]
    if handle then
      if type(handle.bind_runtime) == 'function' then
        handle:bind_runtime(rt)
      end
      local ok, stream_or_err = Protected.pcall(open_parent_stream, rt, driver_scope, handle, which, {
        name = proc.name,
        capacity = opts.capacity,
        read_capacity = opts.read_capacity,
        write_capacity = opts.write_capacity,
        chunk_size = opts.chunk_size,
        read_chunk_size = opts.read_chunk_size,
        write_chunk_size = opts.write_chunk_size,
      })
      if not ok then
        publish_launch_failure(
          rt,
          proc,
          IOError.normalise(stream_or_err, {
            domain = 'process',
            action = 'open_' .. which,
            pid = proc._pid,
          })
        )
        return
      end
      proc[which .. '_pipe_stream'] = stream_or_err
      host_hold:release(which, handle)
    end
  end

  if stdin_source then
    driver_scope:spawn(function()
      return stream_bridge(stdin_source, proc.stdin_pipe_stream, {
        flush = stdin_redirect.flush,
        close_destination = true,
      })
    end, { name = proc.name .. ':stdin-bridge' })
    proc.stdin_stream = nil
  else
    proc.stdin_stream = proc.stdin_pipe_stream
  end
  if stdout_destination then
    driver_scope:spawn(function()
      return stream_bridge(proc.stdout_pipe_stream, stdout_destination, {
        flush = stdout_redirect.flush,
        close_destination = stdout_redirect.close,
      })
    end, { name = proc.name .. ':stdout-bridge' })
    proc.stdout_stream = nil
  else
    proc.stdout_stream = proc.stdout_pipe_stream
  end
  if stderr_destination then
    driver_scope:spawn(function()
      return stream_bridge(proc.stderr_pipe_stream, stderr_destination, {
        flush = stderr_redirect.flush,
        close_destination = stderr_redirect.close,
      })
    end, { name = proc.name .. ':stderr-bridge' })
    proc.stderr_stream = nil
  elseif stderr_mode == 'stdout' then
    proc.stderr_stream = proc.stdout_stream
  else
    proc.stderr_stream = proc.stderr_pipe_stream
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
  IO.masked_perform(rt, proc.launch_completion:publish_success_op(proc))

  local status
  if not proc.lifecycle:is_close_requested() then
    local event, value, err = perform(Op.named_choice({
      { 'exit', proc.host_process:exit_op() },
      { 'close', proc.lifecycle:close_requested_op() },
    }))
    if event == 'exit' then
      status = value
      if not status then
        IO.masked_perform(rt, proc.exit_completion:publish_failure_op(err))
      end
    end
  end

  if not status and proc.lifecycle:is_close_requested() then
    local reason = proc.lifecycle:close_reason() or 'process closed'
    publish_state(rt, proc, { kind = 'closing', pid = proc._pid, reason = reason })
    if proc.stdin_pipe_stream then
      Protected.pcall(function()
        proc.stdin_pipe_stream:abort(reason)
      end)
    end
    local signal_ok, signal_err = host_process:signal(spec.shutdown.signal, spec.shutdown.target)
    if not signal_ok and not IOError.is(signal_err, 'closed') then
      proc._close_error = IOError.normalise(signal_err, {
        domain = 'process',
        action = 'terminate',
        pid = proc._pid,
      })
    end
    local deadline = rt:now() + spec.shutdown.grace
    local exit_err
    status, exit_err = wait_exit_until(proc, deadline)
    if not status and exit_err == 'timeout' then
      host_process:signal(spec.shutdown.kill_signal, spec.shutdown.target)
      status, exit_err = perform(proc.host_process:exit_op())
    end
    if not status then
      IO.masked_perform(rt, proc.exit_completion:publish_failure_op(exit_err))
      proc._close_error = proc._close_error or exit_err
    end
  end

  if status then
    publish_exit(rt, proc, status)
  end

  if not proc.lifecycle:is_close_requested() then
    perform(proc.lifecycle:close_requested_op())
  end
  local reason = proc.lifecycle:close_reason() or 'process closed'
  publish_state(rt, proc, { kind = 'closing', pid = proc._pid, reason = reason, status = status })
  local closed, close_err = finish_close(proc, reason)
  proc._close_error = proc._close_error or close_err
  if closed and not proc._close_error then
    publish_state(rt, proc, { kind = 'closed', pid = proc._pid, status = status })
    IO.masked_perform(rt, proc.closed_completion:publish_success_op(true))
  else
    publish_state(rt, proc, { kind = 'closed', pid = proc._pid, status = status, error = proc._close_error })
    IO.masked_perform(rt, proc.closed_completion:publish_failure_op(proc._close_error))
  end
end

local function driver_body(proc, driver_scope, opts)
  local ok, err = Protected.pcall(supervise, proc, driver_scope, opts)
  if ok then
    return
  end
  local rt = Runtime.current()
  local failure = IOError.is(err) and err
    or IO.protocol_error('process', 'supervisor', err, {
      pid = proc._pid,
      argv = proc.command._spec.argv,
    })
  if proc.launch_completion:is_pending() then
    publish_launch_failure(rt, proc, failure)
  elseif proc.exit_completion:is_pending() then
    IO.masked_perform(rt, proc.exit_completion:publish_failure_op(failure))
  end
  proc._close_error = failure
  if proc.closed_completion:is_pending() then
    IO.masked_perform(rt, proc.closed_completion:publish_failure_op(failure))
  end
end

function Command:launch_op(opts)
  opts = copy_table(opts)
  local command = self
  local spec = command._spec
  if
    spec.shutdown.target == 'group'
    and spec.process_group ~= 'new'
    and type(spec.process_group) ~= 'number'
    and not spec.new_session
  then
    error("group shutdown requires process_group = 'new', a numeric group, or new_session", 2)
  end

  -- Custody comes from the surrounding fibre context and is resolved when the
  -- option is constructed. The Process itself is fresh per guard activation.
  local scope = IO.current_scope(opts, 'Command:launch_op')
  local parent_scope = IO.require_scope(scope, 'Command:launch_op')

  -- A launch option constructs a fresh Process Lifetime for each synchronisation
  -- attempt. The guard is speculative and pure: no host action occurs until the
  -- Process root and its private custody have committed and its Task view starts.
  return Op.guard(function()
    local name = opts.name or 'process'
    local proc = setmetatable({
      kind = 'process',
      name = name,
      command = command,
      lifecycle = Lifecycle.new(name),
      launch_completion = Completion.new(name .. ':launch'),
      exit_completion = Completion.new(name .. ':exit'),
      closed_completion = Completion.new(name .. ':closed'),
      _communicating = false,
      host_hold = HostHold.new(name .. ':host-hold'),
      host_process = nil,
      stdin_stream = nil,
      stdout_stream = nil,
      stderr_stream = nil,
      _pid = nil,
      _status = nil,
      _close_error = nil,
    }, Process)
    Lifetime.define(proc, {
      name = name,
      role = 'process',
      closure = process_closure(proc),
      children = { proc.host_hold },
    })
    local private_scope = Scope.for_lifetime(proc._lifetime)
    proc._task = Task._new(function()
      return private_scope:run(function(driver_scope)
        return driver_body(proc, driver_scope, opts)
      end)
    end, name, parent_scope, { lifetime = proc._lifetime, closure = parent_scope.closure })

    return scope
      :admit_op(proc)
      :and_then(function()
        return proc._task:spawn_effect_op()
      end, false)
      :map(function()
        return proc
      end)
  end)
end

function Command:launch(opts)
  return perform(self:launch_op(opts))
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

function Process:launch_succeeded()
  return perform(self:launch_succeeded_op())
end
function Process:launch_failed()
  return perform(self:launch_failed_op())
end
function Process:launch_result()
  return perform(self:launch_result_op())
end
function Process:result()
  return perform(self:result_op())
end
function Process:signal(signal, target)
  return perform(self:signal_op(signal, target))
end
function Process:terminate()
  return perform(self:terminate_op())
end
function Process:kill()
  return perform(self:kill_op())
end
function Process:request_close(reason)
  return perform(self:request_close_op(reason))
end
function Process:close(reason)
  local ok, err = self:request_close(reason)
  if not ok then
    return nil, err
  end
  return self:closed()
end
function Process:closed()
  return perform(self:closed_op())
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

return Module
