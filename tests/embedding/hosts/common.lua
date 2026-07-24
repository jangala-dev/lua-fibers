package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local FibersRuntime = require('fibers.runtime')
local FibersReadiness = require('fibers.external.readiness')
local FibersRegion = require('fibers.lifetime.region')
local FibersStream = require('fibers.stream')

local Common = {}

function Common.fail(msg)
  error(msg, 2)
end
function Common.assert_truthy(v, msg)
  if not v then
    Common.fail(msg or 'expected truthy')
  end
end
function Common.assert_eq(a, b, msg)
  if a ~= b then
    Common.fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
function Common.assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    Common.fail(
      (msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)
    )
  end
end

function Common.skip(name, reason)
  local result = { status = 'skip', name = name, reason = tostring(reason or 'not available') }
  if not rawget(_G, '_FIBERS_TEST_HARNESS') then
    print(name .. ': skip (' .. result.reason .. ')')
  end
  return result
end

function Common.close_quietly(x)
  if x and type(x.close) == 'function' then
    pcall(function()
      x:close()
    end)
  end
end

function Common.cleanup(host, pipe)
  Common.close_quietly(pipe)
  Common.close_quietly(host)
end

local function run_host(name, host, max_iterations)
  return function(rt)
    return rt:drive({ host = host, max_iterations = max_iterations or 40 })
  end
end

function Common.readiness_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.read_key ~= nil, name .. ' pipe must expose read_key')
  Common.assert_truthy(type(pipe.write_byte) == 'function', name .. ' pipe must expose write_byte')

  local rt = FibersRuntime.new({ host = host })
  local src = FibersReadiness.new(pipe.read_key, 'read', name .. '-readiness')
  local seen, seen_key, seen_mode

  rt:spawn_raw(function()
    seen, seen_key, seen_mode = rt:perform(src:readable_op())
  end, name .. '-reader')

  local ok, err = pipe.write_byte('x')
  Common.assert_truthy(ok, name .. ' pipe write failed: ' .. tostring(err))

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' readiness runner')
  Common.assert_eq(seen, true, name .. ' should deliver readiness')
  Common.assert_eq(seen_key, pipe.read_key, name .. ' should preserve readiness key')
  Common.assert_eq(seen_mode, 'read', name .. ' should deliver read mode')
end

function Common.write_readiness_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.write_key ~= nil, name .. ' pipe must expose write_key')

  local rt = FibersRuntime.new({ host = host })
  local src = FibersReadiness.new(pipe.write_key, 'write', name .. '-write-readiness')
  local seen, seen_key, seen_mode

  rt:spawn_raw(function()
    seen, seen_key, seen_mode = rt:perform(src:writable_op())
  end, name .. '-writer-ready')

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' write readiness runner')
  Common.assert_eq(seen, true, name .. ' should deliver write readiness')
  Common.assert_eq(seen_key, pipe.write_key, name .. ' should preserve write readiness key')
  Common.assert_eq(seen_mode, 'write', name .. ' should deliver write mode')
end

function Common.ready_source_smoke(name, host, key, mode)
  mode = mode or 'read'
  local rt = FibersRuntime.new({ host = host })
  local src = FibersReadiness.new(key, mode, name .. '-ready-source')
  local seen, seen_key, seen_mode

  rt:spawn_raw(function()
    if mode == 'write' or mode == 'wr' then
      seen, seen_key, seen_mode = rt:perform(src:writable_op())
    else
      seen, seen_key, seen_mode = rt:perform(src:readable_op())
    end
  end, name .. '-ready-source-waiter')

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' ready-source runner')
  Common.assert_eq(seen, true, name .. ' should deliver readiness')
  Common.assert_eq(seen_key, key, name .. ' should preserve readiness key')
  Common.assert_eq(
    seen_mode,
    (mode == 'write' or mode == 'wr') and 'write' or mode,
    name .. ' should deliver readiness mode'
  )
end

function Common.readiness_beats_timeout_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.read_key ~= nil, name .. ' pipe must expose read_key')
  Common.assert_truthy(type(pipe.write_byte) == 'function', name .. ' pipe must expose write_byte')

  local rt = FibersRuntime.new({ host = host })
  local src = FibersReadiness.new(pipe.read_key, 'read', name .. '-choice-readiness')
  local winner

  rt:spawn_raw(function()
    -- This is a temporal race.  Keep both waits visible to the host.
    -- or_else is proof-directed fallback and deliberately discards the
    -- preferred branch's wait after the fallback has been entered.
    winner = rt:perform(Op.choice(
      src:readable_op():map(function()
        return 'readiness'
      end),
      Sleep.sleep_op(0.25):map(function()
        return 'timeout'
      end)
    ))
  end, name .. '-readiness-v-timeout')

  local ok, err = pipe.write_byte('x')
  Common.assert_truthy(ok, name .. ' pipe write failed: ' .. tostring(err))

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' readiness should beat timeout')
  Common.assert_eq(winner, 'readiness', name .. ' should choose readiness over later timeout')
end

function Common.timeout_beats_unready_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.read_key ~= nil, name .. ' pipe must expose read_key')

  local rt = FibersRuntime.new({ host = host })
  local src = FibersReadiness.new(pipe.read_key, 'read', name .. '-timeout-readiness')
  local winner

  rt:spawn_raw(function()
    winner = rt:perform(src
      :readable_op()
      :map(function()
        return 'readiness'
      end)
      :or_else(Sleep.sleep_op(0.01):map(function()
        return 'timeout'
      end)))
  end, name .. '-timeout-v-readiness')

  local st = run_host(name, host, 80)(rt)
  Common.assert_status(st, 'found', name .. ' timeout should complete')
  Common.assert_eq(winner, 'timeout', name .. ' should choose timeout when pipe is unready')
end

function Common.handle_stream_pipe_smoke(name, host, Fd)
  local fibers = require('fibers')
  local Handle = require('fibers.host.handle')
  local r, w, perr = Fd.pipe({ host = host, name = name .. ':pipe' })
  Common.assert_truthy(r and w, name .. ' pipe failed: ' .. tostring(perr))
  local handle = Handle.duplex(r, w, { host = host, name = name .. ':duplex' })
  local rt = FibersRuntime.new({ host = host })
  local region = FibersRegion.new(name .. ':region')
  local got, flushed, stream

  rt:spawn_raw(function()
    stream = rt:perform(FibersStream.open_op(handle, {
      owner = region,
      name = name .. ':stream',
      read = true,
      write = true,
      read_capacity = 64,
      write_capacity = 64,
      read_chunk_size = 16,
      write_chunk_size = 16,
    }))
    rt:perform(stream:writer():write_op('hello'))
    flushed = rt:perform(stream:writer():flush_op())
    got = rt:perform(stream:reader():read_exactly_op(5))
    rt:perform(stream:abort_op('test complete'))
  end, name .. ':flow')

  local st = rt:drive({ host = host, max_iterations = 200 })
  Common.assert_status(st, 'found', name .. ' stream pipe runner')
  Common.assert_eq(flushed, true, name .. ' stream flush should succeed')
  Common.assert_eq(got, 'hello', name .. ' stream should loop bytes through pipe')
  handle:close('test')
end

function Common.socket_echo_smoke(name, host, address)
  local socket = require('fibers.socket')
  local report = fibers.try_run(function(scope)
    local listener, listen_err = socket.listen(address, {
      name = name .. ':listener',
      unlink_existing = true,
      unlink_on_close = true,
    })
    Common.assert_truthy(listener, name .. ' listen failed: ' .. tostring(listen_err))
    local actual = listener:local_address()

    local server = scope:spawn(function()
      local connection, accept_err = listener:accept()
      Common.assert_truthy(connection, name .. ' accept failed: ' .. tostring(accept_err))
      local request, read_err = connection:read('*l')
      Common.assert_eq(request, 'ping', name .. ' server read: ' .. tostring(read_err))
      Common.assert_eq(connection:write('pong\n'), 5, name .. ' server write')
      Common.assert_eq(connection:flush(), true, name .. ' server flush')
      connection:close('server complete')
    end, name .. ':server')

    local dial = socket.dial(actual, { name = name .. ':dial' })
    local connection, dial_err = dial:result()
    Common.assert_truthy(connection, name .. ' dial failed: ' .. tostring(dial_err))
    Common.assert_eq(connection:write('ping\n'), 5, name .. ' client write')
    Common.assert_eq(connection:flush(), true, name .. ' client flush')
    local response, response_err = connection:read('*l')
    Common.assert_eq(response, 'pong', name .. ' client read: ' .. tostring(response_err))
    connection:close('client complete')
    server:await()
    listener:close('socket smoke complete')
  end, { host = host, max_iterations = 20000 })
  Common.assert_truthy(report.ok, name .. ' socket smoke failed: ' .. tostring(report.primary))
end

function Common.socket_churn_smoke(name, host, count)
  local socket = require('fibers.socket')
  count = count or 8
  local report = fibers.try_run(function(scope)
    local listener = assert(socket.listen_ipv4('127.0.0.1', 0, {
      name = name .. ':listener',
      accept_capacity = 4,
    }))
    local address = listener:local_address()
    local server = scope:spawn(function()
      for i = 1, count do
        local connection = assert(listener:accept())
        local byte = assert(connection:read(1))
        Common.assert_eq(byte, string.char(64 + i), name .. ' server byte')
        connection:write(byte)
        connection:flush()
        connection:close('server churn complete')
      end
    end, name .. ':server')

    for i = 1, count do
      local dial = socket.dial_ipv4(address.host, address.port, {
        name = name .. ':dial:' .. tostring(i),
      })
      local connection = assert(dial:result())
      local byte = string.char(64 + i)
      connection:write(byte)
      connection:flush()
      Common.assert_eq(connection:read(1), byte, name .. ' client byte')
      connection:close('client churn complete')
    end

    server:await()
    listener:close('native churn complete')
  end, { host = host, max_iterations = 50000 })
  Common.assert_truthy(report.ok, name .. ' socket churn failed: ' .. tostring(report.primary))
end

function Common.native_datagram_smoke(name, host)
  if not (host.capabilities and host.capabilities.datagram) then
    return false, 'host does not advertise datagram capability'
  end
  local socket = require('fibers.socket')
  local report = fibers.try_run(function()
    local left = assert(socket.udp_ipv4('127.0.0.1', 0, { name = name .. ':udp-left' }))
    local right = assert(socket.udp_ipv4('127.0.0.1', 0, { name = name .. ':udp-right' }))
    left:send_to('ping', right:local_address())
    left:flush()
    local packet = assert(right:receive_from())
    Common.assert_eq(packet.data, 'ping', name .. ' datagram payload')
    Common.assert_eq(packet.peer.port, left:local_address().port, name .. ' datagram source port')
    right:send_to('pong', left:local_address())
    right:flush()
    Common.assert_eq(assert(left:receive_from()).data, 'pong', name .. ' datagram reply')
    left:close('datagram smoke complete')
    right:close('datagram smoke complete')
    left:closed()
    right:closed()
  end, { host = host, max_iterations = 50000 })
  Common.assert_truthy(report.ok, name .. ' datagram smoke failed: ' .. tostring(report.primary))
  return true
end

function Common.native_resolver_smoke(name, host)
  if not (host.capabilities and host.capabilities.resolver) then
    return false, 'host does not advertise resolver capability'
  end
  local socket = require('fibers.socket')
  local report = fibers.try_run(function()
    local query = socket.resolve_name('localhost', 80, { family = 'inet4' })
    local addresses, err = query:result()
    Common.assert_truthy(addresses, name .. ' resolver failed: ' .. tostring(err))
    Common.assert_truthy(#addresses >= 1, name .. ' resolver returned no addresses')
    for i = 1, #addresses do
      Common.assert_eq(addresses[i].kind, 'inet4', name .. ' resolver family filter')
      Common.assert_eq(addresses[i].port, 80, name .. ' resolver service port')
    end
    query:close('resolver smoke complete')
  end, { host = host, max_iterations = 2000 })
  Common.assert_truthy(report.ok, name .. ' resolver smoke failed: ' .. tostring(report.primary))
  return true
end

function Common.native_socket_smoke(name, host)
  if not (host.capabilities and host.capabilities.socket) then
    return false, 'host does not advertise socket capability'
  end
  Common.socket_echo_smoke(name .. ':tcp4', host, {
    kind = 'inet4',
    family = 'inet4',
    host = '127.0.0.1',
    port = 0,
  })
  Common.socket_echo_smoke(name .. ':tcp6', host, {
    kind = 'inet6',
    family = 'inet6',
    host = '::1',
    port = 0,
  })
  Common.socket_churn_smoke(name .. ':tcp4-churn', host, 8)
  local path = os.tmpname() .. '.sock'
  os.remove(path)
  Common.socket_echo_smoke(name .. ':unix', host, {
    kind = 'unix',
    family = 'unix',
    path = path,
  })
  os.remove(path)
  return true
end

return Common
