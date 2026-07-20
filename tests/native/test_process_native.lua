local fibers = require('fibers')
local process = require('fibers.process')
local host_module = require('fibers.host.luajit_linux')

local supported, reason = host_module.is_supported()
if not supported then
  return { status = 'skip', reason = reason or 'FFI Linux host unavailable' }
end
local host = host_module.new()
if not host.capabilities.process then
  host:close()
  return { status = 'skip', reason = 'FFI Linux process provider unavailable' }
end

local ok, err = pcall(function()
  local report = fibers.try_run(function()
    local proc, start_err = process
      .command({
        'sh',
        '-c',
        'cat; printf "$FIBERS_PROCESS_TEST" >&2',
        stdin = 'pipe',
        stdout = 'pipe',
        stderr = 'pipe',
        env = { FIBERS_PROCESS_TEST = 'stderr' },
      })
      :start()
    assert(proc, tostring(start_err))
    local captured, capture_err = proc:communicate({
      input = 'stdout',
      stdout_limit = 1024,
      stderr_limit = 1024,
    })
    assert(captured, tostring(capture_err))
    assert(captured.stdout == 'stdout')
    assert(captured.stderr == 'stderr')
    assert(captured.status.kind == 'exited' and captured.status.code == 0)
    assert(proc:close())

    local failed, exec_err = process
      .command({
        '/definitely/not/a/fibers/executable',
        stdout = 'pipe',
        stderr = 'pipe',
      })
      :start()
    assert(failed == nil)
    assert(type(exec_err) == 'table' and exec_err.domain == 'process')
    assert(exec_err.action == 'exec')

    local bad_cwd, cwd_err = process
      .command({
        'true',
        cwd = '/definitely/not/a/fibers/directory',
        stdout = 'pipe',
        stderr = 'pipe',
      })
      :start()
    assert(bad_cwd == nil)
    assert(type(cwd_err) == 'table' and cwd_err.action == 'chdir')

    local nonzero = assert(process
      .command({
        'sh',
        '-c',
        'exit 7',
        stdout = 'pipe',
        stderr = 'pipe',
      })
      :start())
    local result = assert(nonzero:communicate({ stdout_limit = 16, stderr_limit = 16 }))
    assert(result.status.kind == 'exited' and result.status.code == 7 and result.status.success == false)
    assert(nonzero:close())

    local sleeping = assert(process
      .command({
        'sh',
        '-c',
        'sleep 30',
        stdout = 'pipe',
        stderr = 'pipe',
        process_group = 'new',
        shutdown = { grace = 0, target = 'group' },
      })
      :start())
    assert(sleeping:close('native termination test'))
    local stopped = assert(sleeping:result())
    assert(stopped.kind == 'signalled')
  end, { host = host })
  assert(report.ok, report:tostring())
  report.runtime:assert_io_quiescent('native process contract')
end)
host:close()
assert(ok, err)
return true
