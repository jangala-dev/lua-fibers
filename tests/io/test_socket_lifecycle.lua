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
local HostError = require('fibers.host.error')
local Lifecycle = require('fibers.socket.lifecycle')
local ListenerLifecycle = Lifecycle.define({
  prefix = 'socket.listener',
  error_domain = 'socket',
  start_action = 'listen',
  start_failed_reason = 'listener start failed',
  closed_reason = 'listener closed',
})
local DialLifecycle = require('fibers.socket.dial.lifecycle')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

-- Listener state has one authority and idempotent explicit transitions.
do
  fibers.run(function()
    local address = { kind = 'inet', host = '127.0.0.1', port = 8000 }
    local handle = { name = 'listener-handle' }
    local lifecycle = ListenerLifecycle.new('listener-law', address)

    assert_eq(lifecycle:state_value().kind, 'starting')
    assert_eq(fibers.perform(lifecycle:unavailable_op():or_else(Op.always('available'))), 'available')

    local activated, active = fibers.perform(lifecycle:activate_op(handle, address))
    assert_eq(activated, true)
    assert_eq(active.kind, 'active')
    assert_eq(active.handle, handle)

    local first, stopping = fibers.perform(lifecycle:request_stop_op('test close'))
    assert_eq(first, true)
    assert_eq(stopping.kind, 'stopping')
    assert_eq(stopping.handle, handle)

    local second, same = fibers.perform(lifecycle:request_stop_op('second close'))
    assert_eq(second, false)
    assert_eq(same.reason, 'test close', 'first close reason should remain authoritative')

    local unavailable = fibers.perform(lifecycle:unavailable_op())
    assert_eq(unavailable.kind, 'stopping')

    local close_err = HostError.system('socket', 'close_listener', 'close failed', 'EIO')
    assert_eq(fibers.perform(lifecycle:record_close_error_op(close_err)), true)
    local stopped = select(2, fibers.perform(lifecycle:stopped_op('driver stopped')))
    assert_eq(stopped.kind, 'stopped')
    assert_eq(stopped.close_error, close_err)
    assert_eq(stopped.fatal, true)
    assert_eq(fibers.perform(lifecycle:terminal_op()).kind, 'stopped')

    local reactivated = fibers.perform(lifecycle:activate_op({}, address))
    assert_eq(reactivated, false, 'terminal listener must not reactivate')
  end)
end

-- Listener acquisition failure is a direct terminal transition.
do
  fibers.run(function()
    local lifecycle = ListenerLifecycle.new('listener-start-failure', { kind = 'inet' })
    local err = HostError.system('socket', 'listen', 'bind failed', 'EADDRINUSE')
    local published, state = fibers.perform(lifecycle:start_failed_op(err))
    assert_eq(published, true)
    assert_eq(state.kind, 'stopped')
    local value, result_err = fibers.perform(lifecycle:start_result_op())
    assert_eq(value, nil)
    assert_eq(result_err, err)
  end)
end

-- Dial take is a single state transition and certified failure remains absent
-- while an untaken connection exists.
do
  fibers.run(function()
    local lifecycle = DialLifecycle.new('dial-law', { kind = 'inet', port = 443 })
    local connection = { name = 'connection' }
    local source = { name = 'source-scope' }

    assert_eq(lifecycle:state_value().kind, 'starting')
    local published, connected = fibers.perform(lifecycle:publish_connected_op(connection, source))
    assert_eq(published, true)
    assert_eq(connected.kind, 'connected')

    local absence = fibers.perform(lifecycle:failure_op():or_else(Op.always('no failure')))
    assert_eq(absence, 'no failure')

    local taken_connection, taken_source = fibers.perform(lifecycle:take_op())
    assert_eq(taken_connection, connection)
    assert_eq(taken_source, source)
    assert_eq(lifecycle:state_value().kind, 'taken')

    local second = fibers.perform(lifecycle:take_op():or_else(Op.always('already taken')))
    assert_eq(second, 'already taken')
    local err = fibers.perform(lifecycle:failure_op())
    assert_truthy(HostError.is(err, 'closed'))
    assert_eq(err.reason, 'connection already taken')
    assert_eq(fibers.perform(lifecycle:terminal_op()).kind, 'taken')
  end)
end

-- Dial close and failure paths cannot overwrite one another after terminality.
do
  fibers.run(function()
    local closing = DialLifecycle.new('dial-close-law', { kind = 'inet' })
    local first, state = fibers.perform(closing:request_close_op('caller closed'))
    assert_eq(first, true)
    assert_eq(state.kind, 'closing')
    local second = fibers.perform(closing:request_close_op('second close'))
    assert_eq(second, false)
    assert_eq(select(2, fibers.perform(closing:closed_op('driver stopped'))).kind, 'closed')
    local connection, err = fibers.perform(closing:take_op():or_else(closing:failure_op():map(function(e)
      return nil, e
    end)))
    assert_eq(connection, nil)
    assert_truthy(HostError.is(err, 'closed'))

    local failed = DialLifecycle.new('dial-failure-law', { kind = 'inet' })
    local failure = HostError.system('socket', 'dial', 'refused', 'ECONNREFUSED')
    local published, failed_state = fibers.perform(failed:publish_failure_op(failure))
    assert_eq(published, true)
    assert_eq(failed_state.kind, 'failed')
    assert_eq(fibers.perform(failed:failure_op()), failure)
    assert_eq(fibers.perform(failed:publish_connected_op({}, {})), false)
    assert_eq(failed:state_value().kind, 'failed')
  end)
end

print('tests/io/test_socket_lifecycle.lua: ok')
