package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', package.path,
}, ';')

local fibers = require('fibers')
local HostOffer = require('fibers.io.offer')
local HostHandle = require('fibers.io.handle')
local HostError = require('fibers.io.error')
local SimulatedHost = require('tests.support.simulated_host')
local Sleep = require('fibers.sleep')
local Reactor = require('fibers.io.reactor')
local Runtime = require('fibers.runtime')
local FakeHandle = require('tests.support.fake_handle')
local State = require('tests.support.resource_state')

local function assert_eq(a, b, message)
  if a ~= b then error((message or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function readiness_handle(host, name)
  return HostHandle.new({
    label = name,
    key = {},
    host = host,
    close = function() return true end,
  })
end

-- Capacity is owned before the irreversible pull, so a capacity-one source
-- never acquires a second value while the first remains unclaimed.
do
  local host = SimulatedHost.new()
  fibers.run(function(scope)
    local pulls = 0
    local source = HostOffer.new({
      label = 'bounded-offers',
      capacity = 1,
      handle = readiness_handle(host, 'bounded-offers-handle'),
      mode = 'read',
      pull = function()
        pulls = pulls + 1
        return pulls
      end,
    })
    fibers.perform(source:open_op(scope))
    Sleep.sleep(0.001)
    assert_eq(pulls, 1)
    assert_eq(fibers.perform(source:next_op()), 1)
    Sleep.sleep(0.001)
    assert_eq(pulls, 2)
    fibers.perform(source:close_op('test complete'))
    assert(fibers.perform(source:closed_op()))
  end, { host = host })
end

-- Offers and terminal facts enter as external facts. Reactor servicing is not a
-- future transactional supplier which can suppress a nearer deadline.
do
  local host = SimulatedHost.new()
  fibers.run(function(scope)
    local source = HostOffer.new({
      label = 'deadline-offer',
      one_shot = true,
      handle = readiness_handle(host, 'deadline-offer-handle'),
      mode = 'read',
      pull = function()
        return nil, HostError.would_block('test', 'pull')
      end,
    })
    fibers.perform(source:open_op(scope))
    local result = fibers.perform(source:result_op():or_else(Sleep.sleep_op(0.01):map(function()
      return 'deadline'
    end)))
    assert_eq(result, 'deadline')
    fibers.perform(source:close_op('deadline selected'))
    assert(fibers.perform(source:closed_op()))
  end, { host = host })
end

-- A pull is an authoritative non-yielding reactor callback.  Even a raw
-- coroutine yield retires only that source and does not stall unrelated offers.
do
  local host = SimulatedHost.new()
  fibers.run(function(scope)
    local yielding = HostOffer.new({
      label = 'yielding-offer',
      one_shot = true,
      handle = readiness_handle(host, 'yielding-offer-handle'),
      mode = 'read',
      pull = function()
        coroutine.yield('illegal host pull yield')
      end,
    })
    local healthy = HostOffer.new({
      label = 'healthy-offer',
      one_shot = true,
      handle = readiness_handle(host, 'healthy-offer-handle'),
      mode = 'read',
      pull = function()
        return 'healthy'
      end,
    })
    fibers.perform(yielding:open_op(scope))
    fibers.perform(healthy:open_op(scope))

    assert_eq(fibers.perform(healthy:result_op()), 'healthy')
    local value, err = fibers.perform(yielding:result_op())
    assert_eq(value, nil)
    assert(HostError.is(err, 'protocol'))
    assert(tostring(err):match('host reactor pull may not yield'))
  end, { host = host })
end


-- A provider-specific closed_error is the authoritative terminal error for
-- result observers after the host reports closure.
do
  local host = SimulatedHost.new()
  fibers.run(function(scope)
    local translated = HostError.closed('socket', 'accept', { reason = 'translated closure' })
    local source = HostOffer.new({
      label = 'translated-closure-offer',
      handle = readiness_handle(host, 'translated-closure-handle'),
      mode = 'read',
      pull = function()
        return nil, HostError.closed('host', 'read', { reason = 'raw closure' })
      end,
      closed_error = function()
        return translated
      end,
    })
    fibers.perform(source:open_op(scope))
    local value, err = fibers.perform(source:result_op())
    assert_eq(value, nil)
    assert_eq(err, translated, 'closed_error translation should reach result_op')
  end, { host = host })
end

-- Retirement attempts every disposal, restores capacity and publishes terminal
-- state even when disposal callbacks raise.  The same accumulated error reaches
-- terminal observers, closed_op and structural Closure.
do
  local host = SimulatedHost.new()
  local disposed, terminal_err, closed_err = 0
  local result = fibers.try_run(function(scope)
    local next_value = 0
    local source = HostOffer.new({
      label = 'failing-disposal-offer',
      capacity = 2,
      handle = readiness_handle(host, 'failing-disposal-handle'),
      mode = 'read',
      pull = function()
        next_value = next_value + 1
        return next_value
      end,
      dispose = function(value)
        disposed = disposed + 1
        error('dispose failed for ' .. tostring(value), 0)
      end,
    })
    fibers.perform(source:open_op(scope))
    while State.event_queue_length(source._queue) < 2 do Sleep.sleep(0) end
    fibers.perform(source:close_op('exercise disposal failures'))

    local terminal_ok
    terminal_ok, terminal_err = fibers.perform(source:terminal_op())
    assert_eq(terminal_ok, nil)
    local closed_ok
    closed_ok, closed_err = fibers.perform(source:closed_op())
    assert_eq(closed_ok, nil)
    assert_eq(State.event_queue_length(source._queue), 0)
    assert_eq(source._slots._location.value, source._capacity)
  end, { host = host })

  assert_eq(disposed, 2, 'every queued offer should be disposed')
  assert_eq(result.ok, false, 'disposal failure should fail structural Closure')
  assert(HostError.is(terminal_err, 'protocol'))
  assert_eq(terminal_err, closed_err)
  assert_eq(#terminal_err.errors, 2)
end


-- Polling offer sources give providers without a readiness handle the same
-- cached one-shot completion contract without a dedicated task.
do
  local host = SimulatedHost.new({ auto_advance_time = true })
  fibers.run(function(scope)
    local pulls = 0
    local source = HostOffer.new({
      label = 'polling-completion',
      one_shot = true,
      mode = 'poll',
      poll_interval = 0.01,
      pull = function()
        pulls = pulls + 1
        if pulls < 3 then return nil, HostError.would_block('test', 'poll') end
        return 'complete'
      end,
    })
    fibers.perform(source:open_op(scope))
    assert_eq(fibers.perform(source:result_op()), 'complete')
    assert_eq(pulls, 3)
  end, { host = host })
end

-- Reactor callbacks service one shared readiness registration without creating
-- a task per request. The callback is bounded and explicitly clears its hint.
do
  local host = SimulatedHost.new({ auto_advance_time = true })
  fibers.run(function()
    local handle = FakeHandle.new({
      host = host,
      label = 'callback-handle',
      manual_readiness = true,
      initial_writable = false,
    })
    handle:bind_runtime(Runtime.current())
    local calls = 0
    local entry = Reactor.for_runtime():callback({
      label = 'callback-entry',
      mode = 'read',
      handle = handle,
      callback = function(registered_handle)
        calls = calls + 1
        registered_handle:clear_readable()
        return true
      end,
    })
    fibers.perform(entry:register_op())
    Sleep.sleep(0.001)
    assert(entry.armed, 'reactor callback should arm after registration')
    handle:mark_readable()
    Reactor.for_runtime():hint(handle:readiness_key(), 'read')
    Sleep.sleep(0.001)
    assert(calls >= 1, 'reactor callback should service readiness')
    fibers.perform(entry:retire_op('callback test complete'))
    assert(fibers.perform(entry:retired_op()))
    handle:close('callback test complete')
  end, { host = host })
end

print('tests/embedding/test_host_offer.lua: ok')
