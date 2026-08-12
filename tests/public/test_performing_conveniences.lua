package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Load facilities before the facade: direct methods must not depend on facade
-- load order or dynamic prototype mutation.
local channel = require('fibers.channel')
local Closure = require('fibers.closure')
local file = require('fibers.file')
local Grant = require('fibers.grant')
local mailbox = require('fibers.mailbox')
local Pulse = require('fibers.pulse')
local process = require('fibers.process')
local Cell = require('fibers.resource.cell')
local socket = require('fibers.socket')
local Stream = require('fibers.stream')
local Task = require('fibers.task')
local perform = require('fibers.perform')

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local SimulatedHost = require('tests.support.simulated_host')
local Counter = require('fibers.resource.counter')
local Index = require('fibers.resource.index')
local Keyed = require('fibers.resource.keyed')
local ClaimSet = require('fibers.resource.claim_set')
local Flow = require('fibers.resource.flow')
local Signal = require('fibers.resource.signal')
local EventQueue = require('fibers.resource.event_queue')

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

local function assert_no_op_twins(value, names, label)
  for i = 1, #names do
    local name = names[i]
    assert_eq(value[name .. '_op'], nil, (label or 'value') .. ':' .. name .. '_op must not exist')
    assert_eq(type(value[name]), 'function', (label or 'value') .. ':' .. name .. ' causal procedure')
  end
end

assert_eq(fibers.perform, perform, 'contextual prelude exposes the shared perform function')

-- Selected public operations have direct performing conveniences with the same
-- name minus the `_op` suffix.
do
  local rendezvous = channel.new()
  local queue = channel.new(1)
  local unbounded = channel.new(math.huge)
  local cell = Cell.new('idle')
  local pulse = Pulse.new()
  local tx, rx = mailbox.new(1)
  local a = Stream.memory_pair()

  assert_twins(rendezvous, { 'get', 'put' }, 'rendezvous')
  assert_twins(queue, { 'get', 'put' }, 'buffered channel')
  assert_twins(unbounded, { 'get', 'put' }, 'unbounded channel')
  assert(unbounded.capacity == math.huge, 'math.huge should select an unbounded FIFO')
  assert_twins(cell, { 'read', 'expect', 'write', 'wait_until', 'match' }, 'cell')
  assert_twins(pulse, {
    'version', 'why', 'is_closed', 'signal', 'close', 'changed', 'next',
  }, 'pulse')
  assert_twins(tx, { 'send', 'clone', 'close', 'why', 'dropped' }, 'mailbox sender')
  assert_twins(rx, { 'recv', 'why', 'dropped' }, 'mailbox receiver')
  assert_twins(a, {
    'read_some',
    'read_exactly',
    'read_until',
    'read_line',
    'write',
    'write_some',
    'flush',
    'shutdown_read',
    'shutdown_write',
    'abort_write',
    'request_close',
    'request_abort',
    'closed',
  }, 'stream')
  assert_twins(file, { 'submit_pipe', 'submit_tmpfile' }, 'file')
  assert_twins(process.command('true'), { 'launch' }, 'command')
  assert_twins(socket, {
    'submit_listen',
    'submit_listen_inet',
    'submit_listen_unix',
    'submit_udp',
    'dial',
  }, 'socket')
  assert_twins(Stream, { 'merge_lines' }, 'stream module')
  assert_twins(Sleep, { 'sleep', 'sleep_until' }, 'Sleep')

  -- Causal procedures deliberately do not expose a misleading same-stem `_op`.
  assert_twins(a, { 'read_all', 'write_all' }, 'stream')
  assert_no_op_twins(a, { 'close', 'abort' }, 'stream')
  assert_no_op_twins(file, {
    'pipe', 'open', 'tmpfile', 'read_all', 'write_all', 'rename', 'unlink', 'mkdir', 'mkdir_p',
  }, 'file')
  assert_twins(file.RegularFile, { 'read_exactly', 'read_all', 'write_all' }, 'regular file')
  assert_no_op_twins(file.RegularFile, { 'seek', 'flush', 'rename', 'sync', 'close' }, 'regular file')
  assert_no_op_twins(socket, {
    'listen', 'listen_ipv4', 'listen_ipv6', 'listen_inet', 'listen_unix',
    'udp', 'udp_ipv4', 'udp_ipv6',
  }, 'socket')
  assert_no_op_twins(Task, { 'await' }, 'task')

  assert_twins(Counter.new(), {
    'read', 'adjust', 'add', 'bump', 'give', 'take',
    'at_least', 'at_most', 'equal', 'zero',
  }, 'counter')
  assert_twins(Index.new(), {
    'insert', 'insert_auto', 'append', 'remove', 'pop_first', 'pop_last',
  }, 'index')
  local keyed = Keyed.new()
  assert_twins(keyed, { 'get', 'take', 'put', 'insert', 'contains', 'remove' }, 'keyed')
  assert_twins(ClaimSet.new(), { 'acquire', 'release' }, 'claim set')
  local flow = Flow.new()
  assert_twins(flow, { 'abort', 'closed' }, 'flow')
  assert_twins(flow:inlet(), {
    'write', 'write_all', 'write_some', 'reserve_some', 'flush', 'close', 'closed', 'fail',
  }, 'flow inlet')
  assert_twins(flow:outlet(), {
    'read_some', 'read_exactly', 'peek_exactly', 'read_until', 'read_line', 'read_all',
    'drop', 'splice_to', 'lease_some', 'close', 'closed', 'fail',
  }, 'flow outlet')
  assert_twins(Grant, { 'retired' }, 'grant')
  assert_twins(Closure.Failure, { 'retry', 'force' }, 'closure failure')
  assert_twins(Signal.new(), { 'wait' }, 'external signal')
  assert_twins(EventQueue.new(), { 'next' }, 'external event queue')
end

-- Direct methods are exact performing conveniences over their _op forms.
do
  local host = SimulatedHost.new({
    pipes = true,
    sockets = true,
    datagrams = true,
    processes = true,
    auto_advance_time = true,
    on_process_start = function(proc)
      fibers.spawn(function()
        proc:complete({ kind = 'exited', code = 0, success = true })
      end):label('direct-process-child')
    end,
  })
  fibers.run(function()
    local inbox = channel.new()
    local sender = fibers.spawn(function()
      inbox:put('hello')
    end):label('direct-sender')
    assert_eq(inbox:get(), 'hello')
    assert_eq(sender:await(), nil)

    assert_twins(sender, { 'request_cancel' }, 'task')

    local state = Cell.new('idle'):label('state')
    assert_eq(state:read(), 'idle')
    state:write('running')
    assert_eq(state:expect('running'), true)
    assert_eq(state:wait_until(function(value)
      return value == 'running'
    end), 'running')
    local matched, length = state:match(function(value)
      if value == 'running' then
        return true, 'matched:' .. value, #value
      end
    end)
    assert_eq(matched, 'matched:running')
    assert_eq(length, 7)

    local pulse = Pulse.new(0):label('direct-pulse')
    assert_eq(pulse:version(), 0)
    assert_eq(pulse:is_closed(), false)
    assert_eq(pulse:why(), nil)
    assert_eq(pulse:signal(), 1)
    assert_eq(pulse:version(), 1)
    assert_truthy(pulse:close('done'))
    assert_eq(pulse:is_closed(), true)
    assert_eq(pulse:why(), 'done')

    local direct_tx, direct_rx = mailbox.new(1)
    direct_tx:label('direct-mailbox')
    assert_eq(direct_tx:dropped(), 0)
    assert_eq(direct_rx:dropped(), 0)
    assert_eq(direct_tx:why(), nil)
    assert_truthy(direct_tx:close('done'))
    assert_eq(direct_rx:why(), 'done')

    local flow = Flow.new(8):label('direct-flow')
    local inlet, outlet = flow:inlet(), flow:outlet()
    assert_eq(inlet:write('ab'), 2)
    local data_lease = outlet:lease_some(1, 'consumer')
    assert_twins(data_lease, { 'ack', 'release', 'fail' }, 'flow data lease')
    assert_eq(data_lease:bytes(), 'a')
    assert_truthy(data_lease:ack())
    local space_lease = inlet:reserve_some(2, 'producer')
    assert_twins(space_lease, { 'commit', 'release', 'fail' }, 'flow space lease')
    assert_eq(space_lease:commit('cd'), 2)
    assert_eq(outlet:read_exactly(3), 'bcd')
    assert_truthy(inlet:close())
    assert_truthy(inlet:closed())

    local reader, writer = file.pipe({ label = 'direct-pipe' })
    writer:write('one', ' ', 'line\n')
    writer:close('done')
    assert_eq(reader:read_line(), 'one line')
    reader:close('done')

    local listener = assert(socket.listen_inet('127.0.0.1', 0, { label = 'direct-listener' }))
    assert_twins(listener, { 'ready', 'local_address', 'accept', 'request_close', 'closed' }, 'listener')
    assert_no_op_twins(listener, { 'close' }, 'listener')
    local address = listener:local_address()
    local client_task = fibers.spawn(function()
      local dial = assert(socket.dial(socket.inet_address(address.host, address.port), {
        label = 'direct-client',
      }))
      assert_twins(dial, { 'result', 'report', 'request_close', 'closed' }, 'dial')
      assert_no_op_twins(dial, { 'close' }, 'dial')
      local client = assert(dial:result())
      client:write('ping\n')
      assert_eq(client:read_line(), 'pong')
      client:close('done')
    end):label('direct-client-task')

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
    assert_twins(datagram_a, { 'ready', 'local_address', 'send_to', 'receive_from', 'flush', 'request_close', 'closed' }, 'datagram')
    assert_no_op_twins(datagram_a, { 'close' }, 'datagram')
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
      'pid',
      'stdin',
      'stdout',
      'stderr',
      'launch_succeeded',
      'launch_failed',
      'launch_result',
      'result',
      'submit_signal',
      'submit_terminate',
      'submit_kill',
      'request_close',
      'closed',
    }, 'process')
    assert_no_op_twins(child, { 'signal', 'terminate', 'kill', 'communicate', 'close' }, 'process')
    local captured = assert(child:communicate({ stdout_limit = 16, stderr_limit = 16 }))
    assert_eq(captured.status.code, 0)
    assert_truthy(child:close())
    assert_truthy(child:closed())

    -- Explicit option composition remains the same underlying language.
    local timed = fibers.perform(Op.choice(
      Op.always('ready'),
      Sleep.sleep_op(1):map(function()
        return 'late'
      end)
    ))
    assert_eq(timed, 'ready')
  end, { host = host })
end

-- The extracted helper retains the explicit running-fiber boundary and wording.
do
  local ok, err = pcall(function()
    return perform(Op.always(true))
  end)
  assert_eq(ok, false)
  assert_truthy(
    string.find(tostring(err), 'fibers.perform must be called from a running fiber', 1, true) ~= nil
  )
end

print('tests/public/test_performing_conveniences.lua: ok')
