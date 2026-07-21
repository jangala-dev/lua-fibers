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

-- Load facilities before the facade: direct methods must not depend on facade
-- load order or dynamic prototype mutation.
local channel = require('fibers.channel')
local file = require('fibers.file')
local mailbox = require('fibers.mailbox')
local Pulse = require('fibers.pulse')
local process = require('fibers.process')
local Scalar = require('fibers.scalar')
local socket = require('fibers.socket')
local Stream = require('fibers.stream')
local perform = require('fibers.perform')

local fibers = require('fibers')
local Host = require('fibers.host')
local Counter = require('fibers.resource.counter')
local Index = require('fibers.resource.index')
local Keyed = require('fibers.resource.keyed')
local Lease = require('fibers.resource.lease')
local Flow = require('fibers.flow')
local Signal = require('fibers.external.signal')
local EventQueue = require('fibers.external.event_queue')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

local function assert_truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

local function assert_twins(value, names, label)
  for i = 1, #names do
    local name = names[i]
    assert_eq(type(value[name .. '_op']), 'function', (label or 'value') .. ':' .. name .. '_op')
    assert_eq(type(value[name]), 'function', (label or 'value') .. ':' .. name)
  end
end

local function assert_absent(value, names, label)
  for i = 1, #names do
    local name = names[i]
    assert_eq(value[name], nil, (label or 'value') .. ':' .. name .. ' should remain option-only')
  end
end

assert_eq(fibers.perform, perform, 'facade re-exports the shared perform function')

-- Public naming policy: selected conveniences are exact names with only _op
-- removed. Advanced resources and inspection options remain option-only.
do
  local rendezvous = channel.new()
  local queue = channel.new(1)
  local scalar = Scalar.new('idle')
  local pulse = Pulse.new()
  local tx, rx = mailbox.new(1)
  local a = Stream.memory_pair()

  assert_twins(rendezvous, { 'get', 'put' }, 'rendezvous')
  assert_twins(queue, { 'get', 'put' }, 'buffered channel')
  assert_twins(scalar, { 'read', 'changed', 'expect', 'write' }, 'scalar')
  assert_twins(pulse, { 'signal', 'close', 'changed', 'next' }, 'pulse')
  assert_twins(tx, { 'send', 'clone', 'close' }, 'mailbox sender')
  assert_twins(rx, { 'recv' }, 'mailbox receiver')
  assert_eq(rx.receive, nil, 'recv has no long alias')
  assert_twins(a, {
    'read_some',
    'read_exactly',
    'read_until',
    'read_line',
    'read_all',
    'read',
    'write',
    'write_some',
    'flush',
    'shutdown_read',
    'shutdown_write',
    'abort_write',
    'close',
    'abort',
    'closed',
  }, 'stream')
  assert_twins(file, { 'pipe', 'tmpfile' }, 'file')
  assert_twins(process.command('true'), { 'launch' }, 'command')
  assert_eq(process.command('true').start_op, nil, 'command:start is deliberately procedural')
  assert_twins(socket, {
    'listen',
    'listen_inet',
    'listen_unix',
    'udp',
    'dial',
    'dial_inet',
    'dial_unix',
  }, 'socket')
  assert_twins(Stream, { 'merge_lines' }, 'stream module')
  assert_twins(fibers, { 'sleep', 'sleep_until' }, 'fibers')

  assert_absent(scalar, { 'snapshot' }, 'scalar')
  assert_absent(pulse, { 'snapshot', 'version', 'why', 'is_closed' }, 'pulse')
  assert_absent(tx, { 'why', 'dropped', 'snapshot' }, 'mailbox sender')
  assert_absent(rx, { 'why', 'dropped', 'snapshot' }, 'mailbox receiver')
  assert_absent(a, { 'inspect' }, 'stream')
  assert_absent(socket, { 'connect_inet', 'connect_unix' }, 'socket')

  assert_absent(Counter.new(), { 'adjust', 'add', 'give', 'take', 'read', 'state' }, 'counter')
  assert_absent(Index.new(), {
    'insert',
    'insert_auto',
    'append',
    'remove',
    'pop_first',
    'pop_last',
    'snapshot',
  }, 'index')
  assert_absent(Keyed.new(), {
    'get',
    'peek',
    'contains',
    'put',
    'put_absent',
    'remove',
    'remove_present',
    'snapshot',
  }, 'keyed')
  assert_absent(Lease.new(), { 'acquire', 'release', 'snapshot' }, 'lease')
  local flow = Flow.new()
  assert_absent(flow, { 'inspect', 'abort', 'closed' }, 'flow')
  assert_absent(flow:inlet(), { 'write', 'flush', 'close' }, 'flow inlet')
  assert_absent(flow:outlet(), { 'read_some', 'read_line', 'close' }, 'flow outlet')
  assert_absent(Signal.new(), { 'wait' }, 'external signal')
  assert_absent(EventQueue.new(), { 'next' }, 'external event queue')
end

-- Direct methods are exact performing conveniences over their _op forms.
do
  local host = Host.manual({
    pipes = true,
    sockets = true,
    datagrams = true,
    processes = true,
    auto_advance_time = true,
    on_process_start = function(proc)
      fibers.spawn(function()
        proc:complete({ kind = 'exited', code = 0, success = true })
      end, 'direct-process-child')
    end,
  })
  fibers.run(function()
    local inbox = channel.new()
    local sender = fibers.spawn(function()
      inbox:put('hello')
    end, 'direct-sender')
    assert_eq(inbox:get(), 'hello')
    assert_eq(sender:await(), nil)

    assert_twins(sender, { 'await', 'request_cancel' }, 'task')
    assert_absent(sender, { 'exit', 'state', 'cancel' }, 'task')

    local state = Scalar.new('idle', 'state')
    assert_eq(state:read(), 'idle')
    state:write('running')
    assert_eq(state:expect('running'), true)

    local reader, writer = file.pipe({ name = 'direct-pipe' })
    writer:write('one', ' ', 'line\n')
    writer:close('done')
    assert_eq(reader:read('*l'), 'one line')
    reader:close('done')

    local listener = assert(socket.listen_inet('127.0.0.1', 0, { name = 'direct-listener' }))
    assert_twins(listener, { 'accept', 'close', 'closed' }, 'listener')
    local address = listener:local_address()
    local client_task = fibers.spawn(function()
      local dial = assert(socket.dial_inet(address.host, address.port, {
        name = 'direct-client',
      }))
      assert_twins(dial, { 'connected', 'failed', 'result', 'close' }, 'dial')
      local client = assert(dial:result())
      client:write('ping\n')
      assert_eq(client:read_line(), 'pong')
      client:close('done')
    end, 'direct-client-task')

    local server = assert(listener:accept())
    assert_eq(server:read_line(), 'ping')
    server:write('pong\n')
    server:flush()
    server:close('done')
    client_task:await()
    listener:close('done')
    assert_truthy(listener:closed())

    local datagram_a = assert(socket.udp_ipv4('127.0.0.1', 0))
    local datagram_b = assert(socket.udp_ipv4('127.0.0.1', 0))
    assert_twins(datagram_a, { 'send_to', 'receive_from', 'flush', 'close', 'closed' }, 'datagram')
    datagram_a:send_to('packet', datagram_b:local_address())
    datagram_a:flush()
    assert_eq(assert(datagram_b:receive_from()).data, 'packet')
    datagram_a:close('done')
    datagram_b:close('done')
    assert_truthy(datagram_a:closed())
    assert_truthy(datagram_b:closed())

    local child, child_err = process
      .command({
        'manual-child',
        stdout = 'pipe',
        stderr = 'pipe',
      })
      :start()
    assert(child, tostring(child_err))
    assert_twins(child, {
      'launch_succeeded',
      'launch_failed',
      'launch_result',
      'result',
      'signal',
      'terminate',
      'kill',
      'request_close',
      'closed',
      'inspect',
    }, 'process')
    assert_eq(child.communicate_op, nil, 'communicate is deliberately procedural')
    assert_eq(child.close_op, nil, 'close is deliberately request plus wait')
    assert_eq(child.request_signal_op, nil, 'long signal option alias is absent')
    assert_eq(child.request_signal, nil, 'long signal direct alias is absent')
    assert_eq(child.request_terminate_op, nil, 'long terminate option alias is absent')
    assert_eq(child.request_terminate, nil, 'long terminate direct alias is absent')
    assert_eq(child.request_kill_op, nil, 'long kill option alias is absent')
    assert_eq(child.request_kill, nil, 'long kill direct alias is absent')
    local captured = assert(child:communicate({ stdout_limit = 16, stderr_limit = 16 }))
    assert_eq(captured.status.code, 0)
    assert_truthy(child:close())
    assert_truthy(child:closed())

    -- Explicit option composition remains the same underlying language.
    local timed = fibers.perform(fibers.choice(
      fibers.always('ready'),
      fibers.sleep_op(1):map(function()
        return 'late'
      end)
    ))
    assert_eq(timed, 'ready')
  end, { host = host })
end

-- The extracted helper retains the explicit running-fibre boundary and wording.
do
  local ok, err = pcall(function()
    return perform(fibers.always(true))
  end)
  assert_eq(ok, false)
  assert_truthy(
    string.find(tostring(err), 'fibers.perform must be called from a running fiber', 1, true) ~= nil
  )
end

print('tests/public/test_performing_conveniences.lua: ok')
