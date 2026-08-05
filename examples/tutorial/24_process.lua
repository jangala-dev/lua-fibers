package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local SimulatedHost = require('examples.support.simulated_host')
local IOError = require('fibers.io.error')
local process = require('fibers.process')

local host = SimulatedHost.new({
  processes = true,
  pipes = true,
  on_process_start = function(proc, child)
    fibers.spawn(function()
      local runtime = fibers.current_runtime()
      child.stdin:bind_runtime(runtime)
      child.stdout:bind_runtime(runtime)

      local input = {}
      while true do
        fibers.perform(child.stdin:read_ready_op())
        local bytes, err = child.stdin:read(4096)
        if bytes then
          input[#input + 1] = bytes
        elseif IOError.is_eof(err) then
          break
        elseif not IOError.is_would_block(err) then
          error(err, 0)
        end
      end

      child.stdout:write('received: ' .. table.concat(input))
      child.stderr:write('diagnostic')
      proc:complete({ kind = 'exited', code = 0, success = true })
    end):label('example-child')
  end,
})

fibers.run(function()
  local command = process.command({
    'example-child',
    stdin = 'pipe',
    stdout = 'pipe',
    stderr = 'pipe',
  })

  local proc = assert(command:start())
  local result = assert(proc:communicate({
    input = 'hello',
    stdout_limit = 1024,
    stderr_limit = 1024,
  }))

  assert(result.stdout == 'received: hello')
  assert(result.stderr == 'diagnostic')
  assert(process.succeeded(result.status))
  assert(proc:close())
end, { host = host })
