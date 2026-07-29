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
local Host = require('fibers.host')
local SimulatedHost = require('tests.support.simulated_host')
local Handle = require('fibers.host.handle')
local HostError = require('fibers.host.error')
local Address = require('fibers.socket.address')
local Completion = require('fibers.resource.completion')
local HostHold = require('fibers.internal.lifetime.host_hold')
local Connection = require('fibers.socket.connection')

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

-- Declared capabilities, including explicit false values, are authoritative.
do
  local h = Handle.new({
    name = 'capability-handle',
    capabilities = { read = false, write = true, close = false, readiness = true },
    read = function()
      return 'should-not-run'
    end,
    write = function(_, bytes)
      return #bytes
    end,
  })
  assert_eq(h:supports('read'), false)
  assert_eq(h:supports('write'), true)
  local bytes, err = h:read(1)
  assert_eq(bytes, nil)
  assert_truthy(HostError.is_unsupported(err, 'read'))
  local ok, close_err = h:close()
  assert_eq(ok, nil)
  assert_truthy(HostError.is_unsupported(close_err, 'close'))
  local ok2, close_err2 = h:close()
  assert_eq(ok2, nil)
  assert_eq(close_err2, close_err, 'repeat close should preserve the original error')
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
  assert_truthy(SimulatedHost.new({ pipes = true }).capabilities.pipe == true)
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
  local completion = Completion.new('completion-test')
  local observed, second
  fibers.run(function()
    fibers.spawn(function()
      observed = { fibers.perform(completion:result_op()) }
    end, 'completion-waiter')
    fibers.perform(completion:publish_success_op('done'))
    local changed, conflict = fibers.perform(completion:publish_failure_op('late'))
    second = conflict and conflict.kind or changed
  end)
  assert_eq(observed[1], 'done')
  assert_eq(second, 'completion_already_terminal')
  assert_eq(completion:state_value().kind, 'succeeded')
end

-- An admitted internal host hold closes an unreleased host value during Lifetime Closure.
do
  local closed = 0
  fibers.run(function(scope)
    local host_hold = HostHold.new('settled-host-hold')
    fibers.perform(scope:admit_op(host_hold))
    local value = { name = 'external' }
    assert_eq(
      host_hold:hold('value', value, function(v, reason)
        assert_eq(v, value)
        assert_truthy(reason ~= nil)
        closed = closed + 1
        return true
      end),
      value
    )
  end)
  assert_eq(closed, 1)
end

-- Releasing a held value after permanent custody transfer prevents backup closure.
do
  local closed = 0
  fibers.run(function(scope)
    local host_hold = HostHold.new('released-host-hold')
    fibers.perform(scope:admit_op(host_hold))
    local value = {}
    host_hold:hold('value', value, function()
      closed = closed + 1
      return true
    end)
    assert_eq(host_hold:release('value', value), value)
  end)
  assert_eq(closed, 0)
end

-- Failure while converting one held accepted handle closes only that key;
-- sibling offers in the shared source hold remain valid.
do
  local first_closed, second_closed = 0, 0
  fibers.run(function(scope)
    local hold = HostHold.new('keyed-discard-host-hold')
    fibers.perform(scope:admit_op(hold))

    local first = Handle.new({
      name = 'invalid-accepted-handle',
      capabilities = { read = false, write = true, close = true, readiness = true },
      write = function(_, bytes)
        return #bytes
      end,
      close = function()
        first_closed = first_closed + 1
        return true
      end,
    })
    local second = Handle.new({
      name = 'queued-sibling-handle',
      capabilities = { close = true, readiness = true },
      close = function()
        second_closed = second_closed + 1
        return true
      end,
    })

    assert_eq(
      hold:hold('first', first, function(value, reason)
        return value:close(reason)
      end),
      first
    )
    assert_eq(
      hold:hold('second', second, function(value, reason)
        return value:close(reason)
      end),
      second
    )

    local connection, err = Connection.from_host_hold(fibers.current_runtime(), scope, hold, 'first', first, {
      name = 'invalid-accepted-connection',
      action = 'open_accepted_stream',
    })
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err), 'conversion failure should be normalised as a HostError')
    assert_truthy(tostring(err):match('read capability'), 'conversion failure should retain its cause')
    assert_eq(first_closed, 1, 'failed selected handle should close exactly once')
    assert_eq(second_closed, 0, 'sibling held handle must remain open')
    assert_eq(hold.values.second.value, second)
    assert_eq(hold.closed, false)

    assert_eq(hold:release('second', second), second)
    assert_eq(second:close('test complete'), true)
  end)
  assert_eq(second_closed, 1)
end

-- Completion can expose pending as an option for single-winner protocols.
do
  local Completion = require('fibers.resource.completion')
  local completion = Completion.new('pending-completion')
  fibers.run(function()
    assert_eq(fibers.perform(completion:pending_op()), true)
    fibers.perform(completion:publish_success_op('done'))
    assert_eq(fibers.perform(completion:pending_op():or_else(Op.always(false))), false)
  end)
end

print('tests/io/test_foundations.lua: ok')
