local IOAudit = require('fibers.diagnostics.io')
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local SimulatedHost = require('tests.support.simulated_host')
local HostError = require('fibers.io.error')
local Stream = require('fibers.stream')
local process = require('fibers.process')

local function assert_eq(a, b, msg)
  assert(a == b, (msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
end

-- Command is a pure reusable value.
do
  local base = process.command('worker', '--once')
  local changed = base:with_stdout('pipe'):with_env({ MODE = 'test' })
  assert_eq(base:spec().stdout, 'inherit')
  assert_eq(changed:spec().stdout, 'pipe')
  assert_eq(base:argv()[1], 'worker')
  assert_eq(changed:spec().env.MODE, 'test')
  local shell = process.shell('printf hello')
  assert_eq(shell:argv()[1], '/bin/sh')
  assert_eq(shell:argv()[2], '-c')
  assert_eq(shell:argv()[3], 'printf hello')
  local invalid_group = process.command({
    'worker',
    shutdown = { target = 'group' },
  })
  local ok = pcall(function()
    return invalid_group:launch_op()
  end)
  assert_eq(ok, false, 'group shutdown requires explicit group ownership')
end

-- launch_op is synchronisation-local and admits a fresh Process without waiting
-- for the external launch handshake. start is the direct launch-plus-handshake
-- convenience.
do
  local starts = 0
  local host = SimulatedHost.new({
    processes = true,
    pipes = true,
    on_process_start = function(proc)
      starts = starts + 1
      proc:complete({ kind = 'exited', code = 0, success = true })
    end,
  })

  local command = process.command({ 'guarded-launch', stdout = 'pipe', stderr = 'pipe' })

  fibers.run(function()
    local skipped = fibers.perform(Op.always('skip'):or_else(command:launch_op()))
    assert_eq(skipped, 'skip')
    assert_eq(starts, 0, 'an unselected launch option performs no host work')

    local launch = command:launch_op()
    assert_eq(starts, 0, 'constructing launch_op performs no host work')
    local first = fibers.perform(launch)
    local second = fibers.perform(launch)
    assert(first ~= second, 'each synchronisation attempt receives a fresh Process')
    local first_launched, first_launch_err = first:launch_result()
    assert(first_launched, tostring(first_launch_err))
    local second_launched, second_launch_err = second:launch_result()
    assert(second_launched, tostring(second_launch_err))
    assert(first:result())
    assert(second:result())
    assert(first:close())
    assert(second:close())
  end, { host = host })

  assert_eq(starts, 2, 'each committed launch starts exactly one host process')
end

-- Fixed output and status through ManualHost.
do
  local host = SimulatedHost.new({
    processes = true,
    pipes = true,
    on_process_start = function(proc, child)
      fibers.spawn(function()
        child.stdout:write('hello')
        child.stderr:write('warning')
        proc:complete({ kind = 'exited', code = 0, success = true })
      end):label('manual-child')
    end,
  })

  local captured_result
  local report = fibers.try_run(function()
    local proc, err = process.command({ 'fake', stdout = 'pipe', stderr = 'pipe' }):start()
    assert(proc, tostring(err))
    local captured, capture_err = proc:communicate({ stdout_limit = 128, stderr_limit = 128 })
    assert(captured, tostring(capture_err))
    assert_eq(captured.stdout, 'hello')
    assert_eq(captured.stderr, 'warning')
    assert(process.succeeded(captured.status))
    assert_eq(proc:result(), captured.status, 'result must be cached')
    local second, second_err = proc:communicate({ stdout_limit = 128, stderr_limit = 128 })
    assert(second == nil)
    assert(HostError.is(second_err, 'invalid_argument'))
    assert(proc:close())
    assert(proc:close('idempotent close'))
    captured_result = captured
  end, { host = host })
  assert(report.ok, report:tostring())
  IOAudit.assert_clean(report.runtime, { label = 'manual process contract' })
  assert_eq(captured_result.status.code, 0)
end

-- Piped input reaches the child and output is drained without deadlock.
do
  local host = SimulatedHost.new({
    processes = true,
    pipes = true,
    on_process_start = function(proc, child)
      fibers.spawn(function()
        local rt = fibers.current_runtime()
        child.stdin:bind_runtime(rt)
        child.stdout:bind_runtime(rt)
        while true do
          fibers.perform(child.stdin:read_ready_op())
          local bytes, err = child.stdin:read(4096)
          if bytes then
            child.stdout:write(bytes)
          elseif HostError.is_eof(err) then
            break
          elseif not HostError.is_would_block(err) then
            error(err, 0)
          end
        end
        proc:complete({ kind = 'exited', code = 0, success = true })
      end):label('manual-echo-child')
    end,
  })

  fibers.run(function()
    local proc = assert(process
      .command({
        'echo-child',
        stdin = 'pipe',
        stdout = 'pipe',
        stderr = 'pipe',
      })
      :start())
    local captured = assert(proc:communicate({
      input = 'request',
      stdout_limit = 128,
      stderr_limit = 128,
    }))
    assert_eq(captured.stdout, 'request')
    assert_eq(captured.stderr, '')
    assert(proc:close())
  end, { host = host })
end

-- stderr may be merged into stdout without creating a second public Stream.
do
  local host = SimulatedHost.new({
    processes = true,
    pipes = true,
    on_process_start = function(proc, child)
      fibers.spawn(function()
        child.stdout:write('out')
        child.stderr:write('err')
        proc:complete({ kind = 'exited', code = 0, success = true })
      end):label('manual-combined-output-child')
    end,
  })

  fibers.run(function()
    local proc = assert(process
      .command({
        'combined-output',
        stdout = 'pipe',
        stderr = 'stdout',
      })
      :start())
    assert(proc:stderr() == proc:stdout())
    local captured = assert(proc:communicate({ stdout_limit = 128 }))
    assert_eq(captured.stdout, 'outerr')
    assert(captured.stderr == nil)
    assert(proc:close())
  end, { host = host })
end

-- Supplied Streams are bridged without transferring or requiring a descriptor.
do
  local host = SimulatedHost.new({
    processes = true,
    pipes = true,
    on_process_start = function(proc, child)
      fibers.spawn(function()
        child.stdout:write('redirected')
        proc:complete({ kind = 'exited', code = 0, success = true })
      end):label('manual-redirect-child')
    end,
  })

  fibers.run(function()
    local destination, reader = Stream.memory_pair({ label = 'process-redirect' })
    local proc = assert(process
      .command({
        'redirect-child',
        stdout = destination,
        stderr = 'null',
      })
      :start())
    assert(proc:stdout() == nil)
    assert(proc:result())
    local text = assert(reader:read_exactly(#'redirected'))
    assert_eq(text, 'redirected')
    assert(proc:close())
    destination:close()
    reader:close()
  end, { host = host })
end

-- Caller timeout remains distinct from process failure; close performs TERM and reap.
do
  local host = SimulatedHost.new({ processes = true, pipes = true })
  fibers.run(function()
    local proc = assert(process
      .command({
        'long-running',
        stdout = 'pipe',
        stderr = 'pipe',
        shutdown = { grace = 0 },
      })
      :start())
    local value = fibers.perform(Op.choice(
      proc:result_op():map(function()
        return 'process'
      end),
      Sleep.sleep_op(0.01):map(function()
        return 'timeout'
      end)
    ))
    assert_eq(value, 'timeout')
    assert(proc:close('timeout'))
    local status = assert(proc:result())
    assert_eq(status.kind, 'signalled')
  end, { host = host })
end

-- Capture limits close the process rather than waiting indefinitely for exit.
do
  local host = SimulatedHost.new({
    processes = true,
    pipes = true,
    on_process_start = function(proc, child)
      fibers.spawn(function()
        child.stdout:write(string.rep('x', 256))
        proc:complete({ kind = 'exited', code = 0, success = true })
      end):label('manual-large-output-child')
    end,
  })

  fibers.run(function()
    local proc = assert(process
      .command({
        'large-output',
        stdout = 'pipe',
        stderr = 'pipe',
        shutdown = { grace = 0 },
      })
      :start())
    local result, err = proc:communicate({ stdout_limit = 8, stderr_limit = 8 })
    assert(result == nil)
    assert(err ~= nil)
    assert(proc:closed())
  end, { host = host })
end

-- Unsupported hosts fail through the normal start result.
do
  local host = SimulatedHost.new({ processes = false })
  fibers.run(function()
    local proc, err = process.command('missing'):start()
    assert(proc == nil)
    assert(HostError.is_unsupported(err, 'process'))
  end, { host = host })
end


-- All host strategies cross one validated provider boundary beneath the Process
-- Lifetime. An invalid provider handle fails as a structured protocol error and
-- any returned host values are closed immediately.
do
  local process_closed, endpoint_closed = false, false
  local host = SimulatedHost.new({
    processes = true,
    process_factory = function()
      return {
        pid = function() return 991 end,
        close = function()
          process_closed = true
          return true
        end,
        -- deliberately missing open_exit_op, exit_op and signal
      }, {
        stdout = {
          close = function()
            endpoint_closed = true
            return true
          end,
        },
      }
    end,
  })

  fibers.run(function()
    local proc, err = process.command({ 'invalid-provider', stdout = 'pipe' }):start()
    assert(proc == nil)
    assert(HostError.is(err, 'protocol'))
    assert_eq(err.action, 'start_process')
    assert_eq(err.missing, 'open_exit_op')
  end, { host = host })
  assert(process_closed, 'invalid provider process handle should be closed')
  assert(endpoint_closed, 'invalid provider endpoints should be closed')
end

return true
