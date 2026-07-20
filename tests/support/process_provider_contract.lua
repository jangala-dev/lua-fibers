local fibers = require('fibers')
local process = require('fibers.process')

local Contract = {}

local function assert_truthy(value, message)
  if not value then error(message or 'expected truthy value', 3) end
  return value
end

function Contract.exercise(name, host)
  local report = fibers.try_run(function()
    local proc, start_err = process.command({
      'sh', '-c', 'cat; printf "$FIBERS_PROCESS_TEST" >&2',
      stdin = 'pipe', stdout = 'pipe', stderr = 'pipe',
      env = { FIBERS_PROCESS_TEST = 'stderr' },
    }):start()
    assert_truthy(proc, name .. ' start failed: ' .. tostring(start_err))
    local captured, capture_err = proc:communicate({
      input = 'stdout', stdout_limit = 1024, stderr_limit = 1024,
    })
    assert_truthy(captured, name .. ' communicate failed: ' .. tostring(capture_err))
    assert(captured.stdout == 'stdout', name .. ' stdout mismatch')
    assert(captured.stderr == 'stderr', name .. ' stderr mismatch')
    assert(captured.status.kind == 'exited' and captured.status.code == 0, name .. ' successful status')
    assert(proc:close())

    local failed, exec_err = process.command({
      '/definitely/not/a/fibers/executable', stdout = 'pipe', stderr = 'pipe',
    }):start()
    assert(failed == nil, name .. ' missing executable should fail at launch')
    assert(type(exec_err) == 'table' and exec_err.domain == 'process', name .. ' structured exec error')
    assert(exec_err.action == 'exec', name .. ' honest exec failure')

    local bad_cwd, cwd_err = process.command({
      'true', cwd = '/definitely/not/a/fibers/directory', stdout = 'pipe', stderr = 'pipe',
    }):start()
    assert(bad_cwd == nil, name .. ' invalid cwd should fail at launch')
    assert(type(cwd_err) == 'table' and cwd_err.action == 'chdir', name .. ' honest cwd failure')

    local nonzero = assert(process.command({
      'sh', '-c', 'exit 7', stdout = 'pipe', stderr = 'pipe',
    }):start())
    local result = assert(nonzero:communicate({ stdout_limit = 16, stderr_limit = 16 }))
    assert(result.status.kind == 'exited' and result.status.code == 7 and result.status.success == false,
      name .. ' non-zero status')
    assert(nonzero:close())

    local replaced = assert(process.command({
      '/bin/sh', '-c', 'printf "%s:%s" "${FIBERS_ONLY-unset}" "${HOME-unset}"', stdout = 'pipe', stderr = 'pipe',
      env_mode = 'replace', env = { FIBERS_ONLY = 'present' },
    }):start())
    local replaced_result = assert(replaced:communicate({ stdout_limit = 128, stderr_limit = 128 }))
    assert(replaced_result.stdout == 'present:unset', name .. ' environment replacement')
    assert(replaced:close())

    local sleeping = assert(process.command({
      'sh', '-c', 'sleep 30', stdout = 'pipe', stderr = 'pipe',
      process_group = 'new',
      shutdown = { grace = 0, target = 'group' },
    }):start())
    assert(sleeping:close(name .. ' termination test'))
    local stopped = assert(sleeping:result())
    assert(stopped.kind == 'signalled', name .. ' group termination')
  end, { host = host })
  assert_truthy(report.ok, name .. ' process contract failed: ' .. report:tostring())
  report.runtime:assert_io_quiescent(name .. ' process contract')
  return true
end

return Contract
