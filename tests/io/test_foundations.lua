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
local Op = require('fibers.op')
local SimulatedHost = require('tests.support.simulated_host')
local Handle = require('fibers.io.handle')
local HostError = require('fibers.io.error')
local Address = require('fibers.net.address')
local Completion = require('fibers.resource.completion')
local Connection = require('fibers.socket.connection')
local State = require('tests.support.resource_state')

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

-- A concrete HostHandle has one source of truth for capability: its callback set.
do
  local missing_close = pcall(function()
    Handle.new({
      label = 'missing-close-handle',
      read = function() return 'x' end,
    })
  end)
  assert_eq(missing_close, false, 'every HostHandle must provide close')

  local h = Handle.new({
    label = 'capability-handle',
    write = function(_, bytes) return #bytes end,
    close = function() return true end,
  })
  assert_eq(h:supports('read'), false)
  assert_eq(h:supports('write'), true)
  assert_eq(h:supports('close'), true)
  local bytes, err = h:read(1)
  assert_eq(bytes, nil)
  assert_truthy(HostError.is_unsupported(err, 'read'))
end

-- Host errors are stable tagged values with useful predicates and text.
do
  local err = HostError.system('socket', 'connect', 'connection refused', 'ECONNREFUSED', 111)
  assert_truthy(HostError.is(err, 'system'))
  assert_eq(err.domain, 'socket')
  assert_eq(err.action, 'connect')
  assert_eq(tostring(err), 'connection refused')
  assert_truthy(HostError.is_would_block(HostError.would_block('fd', 'read')))
  assert_truthy(HostError.is_eof(HostError.eof('fd', 'read')))
  assert_truthy(SimulatedHost.new({ pipes = true }):supports('pipe'))
end

-- Public Unix endpoints require a pathname, while native queries may report
-- an unnamed local or peer endpoint.
do
  assert_eq(Address.decode_unix(nil), nil)
  assert_eq(Address.decode_unix(''), nil)
  local address = Address.decode_unix('/tmp/fibers.sock')
  assert_eq(address.kind, 'unix')
  assert_eq(address.path, '/tmp/fibers.sock')
  local ok = pcall(Address.unix, '')
  assert_eq(ok, false, 'public Unix addresses must remain non-empty')
end

-- Completion publishes one terminal result and wakes result waiters.
do
  local completion = Completion.new():label('completion-test')
  local observed, second
  fibers.run(function()
    fibers.spawn(function()
      observed = { fibers.perform(completion:result_op()) }
    end):label('completion-waiter')
    fibers.perform(completion:publish_success_op('done'))
    local changed, conflict = fibers.perform(completion:publish_failure_op('late'))
    second = conflict and conflict.kind or changed
  end)
  assert_eq(observed[1], 'done')
  assert_eq(second, 'completion_already_terminal')
  assert_eq(State.completion(completion).kind, 'succeeded')
end

-- Completion can expose pending as an option for single-winner protocols.
do
  local Completion = require('fibers.resource.completion')
  local completion = Completion.new():label('pending-completion')
  fibers.run(function()
    assert_eq(fibers.perform(completion:pending_op()), true)
    fibers.perform(completion:publish_success_op('done'))
    assert_eq(fibers.perform(completion:pending_op():or_else(Op.always(false))), false)
  end)
end

print('tests/io/test_foundations.lua: ok')
