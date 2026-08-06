package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Portable fake-engine conformance: this file intentionally runs under stock
-- Lua and generated Luau. Real Roblox Instance integration is tested separately
-- in Studio; these tests verify the shared driver, buffering and lifetime logic.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local Rendezvous = require('fibers.resource.rendezvous')
local Roblox = require('fibers.roblox')
local RobloxHost = require('fibers.roblox.host')
local Protected = require('fibers.protected')
local unpack_ = table.unpack or unpack
local FakeTask = require('tests.support.roblox.fake_task')
local FakeEvent = require('tests.support.roblox.fake_event')
local FakeSignal = require('tests.support.roblox.fake_signal')
local FakeGame = require('tests.support.roblox.fake_game')

local function fail(message)
  error(message, 2)
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    fail((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end

local function assert_truthy(value, message)
  if not value then
    fail(message or 'expected truthy value')
  end
end

local function new_host(scheduler, opts)
  opts = opts or {}
  opts.task = scheduler.api
  opts.now = opts.now or function()
    return scheduler.now
  end
  opts.make_event = opts.make_event or function(name)
    return FakeEvent.new(scheduler, name)
  end
  return RobloxHost.new(opts)
end

local function run_scheduled(scheduler, fn)
  local done, values = false
  scheduler.api.defer(function()
    values = { Protected.pcall(fn) }
    done = true
  end)
  assert_truthy(
    scheduler:run_until(function()
      return done
    end),
    'scheduled program did not complete'
  )
  scheduler:run_until_idle()
  if not values[1] then
    error(values[2], 0)
  end
  return unpack_(values, 2)
end

local function advance_until_settled(app, limit)
  limit = limit or 1000
  local status
  for _ = 1, limit do
    status = app:advance({ max_seconds = 1000 })
    if status.state == 'settled' then
      return status
    end
    if not status.needs_immediate_resume then
      return status
    end
  end
  error('manual Roblox application exceeded advance limit', 2)
end

-- Manual prepare needs neither a scheduler nor a BindableEvent bridge.
do
  local host = Roblox.new_host({
    now = function() return 0 end,
    task = false,
    make_event = false,
  })
  local app = Roblox.prepare(function()
    return 'manual-only'
  end, { host = host, owns_host = false })
  local status = app:advance({ horizon = 1, max_steps = 32, max_work = 256 })
  assert_eq(status.state, 'settled')
  assert_eq(app:result():raise(), 'manual-only')
  app:close()
  host:close()
end

-- Roblox is explicitly selected because Host.default is reserved for standalone drivers.
do
  local scheduler = FakeTask.new()
  local selected = Roblox.new_host({
    task = scheduler.api,
    now = function()
      return scheduler.now
    end,
    make_event = function(name)
      return FakeEvent.new(scheduler, name)
    end,
  })
  assert_eq(selected.kind, 'roblox')
  local progressed, reason = selected:block()
  assert_eq(progressed, nil)
  assert_eq(reason, 'roblox-host-is-embedded-use-fibers.roblox')
  selected:close()
  scheduler:run_until_idle()
end

-- Wake requests are coalesced until the next application advance consumes them.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local wakes = 0
  host:set_wake_callback(function()
    wakes = wakes + 1
  end)
  host:wake('first')
  host:wake('second')
  assert_eq(wakes, 1, 'pending wakes should be coalesced')
  assert_eq(host:consume_wake(), 'first')
  host:wake('third')
  assert_eq(wakes, 2)
  host:close()
  scheduler:run_until_idle()
end

-- prepare exposes the canonical non-blocking, manually driven boundary.
do
  local scheduler = FakeTask.new(10)
  local host = new_host(scheduler)
  local woke = false
  local app = Roblox.prepare(function()
    fibers.perform(Sleep.sleep_op(2))
    woke = true
  end, {
    host = host,
    owns_host = false,
    max_seconds_per_turn = 100,
  })

  local status = advance_until_settled(app)
  assert_eq(status.state, 'pending')
  assert_eq(status.reason, 'wakeup')
  assert_eq(status.next_deadline, 12)
  assert_truthy(not woke)

  scheduler.now = 12
  status = advance_until_settled(app)
  assert_eq(status.state, 'settled')
  assert_truthy(app:result().ok)
  assert_truthy(woke)
  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- A host step budget yields retained immediate work rather than blocking Roblox.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local completed = false
  local app = Roblox.prepare(function()
    fibers.perform(Op.always(true))
    completed = true
  end, {
    host = host,
    owns_host = false,
    max_steps_per_turn = 1,
    max_seconds_per_turn = 100,
  })

  local first = app:advance()
  assert_eq(first.state, 'pending')
  assert_eq(first.reason, 'turn-budget')
  assert_truthy(first.needs_immediate_resume)
  assert_truthy(not app:is_settled())

  local final = advance_until_settled(app)
  assert_eq(final.state, 'settled')
  assert_truthy(completed)
  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- A temporary quiescent result does not hide other fibers already ready to run.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local side_fiber_ran = false
  local app = Roblox.prepare(function()
    fibers.perform(Op.never())
  end, {
    host = host,
    owns_host = false,
    max_steps_per_turn = 1,
    max_seconds_per_turn = 100,
  })
  app.runtime:spawn_raw(function()
    side_fiber_ran = true
  end):label('ready-behind-quiescent-root')

  local first = app:advance()
  assert_eq(first.state, 'pending')
  assert_truthy(first.needs_immediate_resume)
  assert_truthy(not app:is_settled(), 'ready work must prevent premature quiescent completion')

  for _ = 1, 4 do
    if side_fiber_ran then
      break
    end
    app:advance()
  end
  assert_truthy(side_fiber_ran, 'the ready side fiber should receive a later bounded turn')
  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- Hard proof-capacity limits stop automatic rescheduling without becoming Retry.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local app = Roblox.prepare(function()
    fibers.perform(Op.never())
  end, {
    host = host,
    owns_host = false,
    runtime_options = { search_total_limit = 5 },
    max_steps_per_turn = 100,
    max_seconds_per_turn = 100,
  })

  local workers = {}
  for i = 1, 8 do
    workers[i] = Rendezvous.new():label('roblox-capacity-worker-' .. tostring(i))
    local index = i
    app.runtime:spawn_raw(function()
      app.runtime:perform(workers[index]:get_op())
    end):label('roblox-capacity-worker-' .. tostring(i))
  end
  app.runtime:spawn_raw(function()
    local jobs = {}
    for job = 1, 8 do
      local alternatives = {}
      for worker = 1, 8 do
        alternatives[worker] = workers[worker]:put_op(job)
      end
      jobs[job] = Op.choice(alternatives)
    end
    app.runtime:perform(Op.each(jobs))
  end):label('roblox-capacity-dispatcher')

  local status = app:advance()
  assert_eq(status.state, 'pending')
  assert_eq(status.reason, 'proof-capacity')
  assert_eq(status.capacity_reason, 'search_total_limit')
assert_truthy(not status.needs_immediate_resume)
  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- An absolute time horizon is a scheduling boundary, not semantic Retry.
do
  local scheduler = FakeTask.new()
  local clock = 0
  local host = new_host(scheduler, {
    now = function()
      clock = clock + 1
      return clock
    end,
  })
  local app = Roblox.prepare(function()
    fibers.perform(Op.always('committed'))
  end, {
    host = host,
    owns_host = false,
    max_steps_per_turn = 100,
    max_seconds_per_turn = 0,
  })

  local status = app:advance()
  assert_eq(status.state, 'pending')
  assert_eq(status.reason, 'horizon')
  assert_truthy(status.needs_immediate_resume)
  assert_truthy(status.runtime_status.tag == 'found' or status.runtime_status.tag == 'pending')

  status = advance_until_settled(app)
  assert_eq(status.state, 'settled')
  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- Event scheduling uses one delayed wake for a Fibers deadline.
do
  local scheduler = FakeTask.new(10)
  local host = new_host(scheduler)
  local woke = false
  run_scheduled(scheduler, function()
    local result = Roblox.try_run(function()
      fibers.perform(Sleep.sleep_op(2))
      woke = true
    end, { host = host, owns_host = false })
    assert_truthy(result.ok, 'timer program should succeed')
  end)
  assert_truthy(woke, 'timer should resume the Fibers fiber')
  assert_eq(scheduler.now, 12, 'fake Roblox clock should reach the deadline')
  host:close()
  scheduler:run_until_idle()
end

-- Immediate engine signals are queued rather than re-entering a running fiber.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local signal = FakeSignal.new('SkipButton.Activated')
  local selected

  run_scheduled(scheduler, function()
    selected = Roblox.run(function()
      local skip = Roblox.events(signal, { name = 'cutscene-skip' })
      signal:Fire('player pressed Skip') -- fires while Runtime phase is `fiber`
      return skip:next()
    end, { host = host, owns_host = false })
  end)

  assert_eq(selected, 'player pressed Skip')
  assert_eq(signal:connection_count(), 0, 'Scope Closure should disconnect the signal')
  host:close()
  scheduler:run_until_idle()
end

-- An external event which wins a choice cancels the stale scheduled deadline.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local signal = FakeSignal.new('Prompt.Triggered')
  local selected

  run_scheduled(scheduler, function()
    selected = Roblox.run(function()
      local prompt = Roblox.events(signal)
      scheduler.api.delay(1, function()
        signal:Fire('accepted')
      end)
      return fibers.perform(Op.choice(
        prompt:next_op():wrap(function(value)
          return 'prompt', value
        end),
        Sleep.sleep_op(10):wrap(function()
          return 'deadline'
        end)
      ))
    end, { host = host, owns_host = false })
  end)

  assert_eq(selected, 'prompt')
  assert_eq(scheduler.now, 1, 'cancelled deadline should not advance fake time')
  host:close()
  scheduler:run_until_idle()
end

-- A manual host boundary makes queued, latest and pulse semantics observable.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local actions_signal = FakeSignal.new('Actions')
  local health_signal = FakeSignal.new('Health')
  local navigation_signal = FakeSignal.new('NavigationInvalidated')
  local actions, newest_health, navigation_generation

  local app = Roblox.prepare(function()
    local action_events = Roblox.events(actions_signal, { name = 'every-action' })
    local health = Roblox.latest(health_signal, { name = 'newest-health' })
    local navigation = Roblox.pulse(navigation_signal, { name = 'navigation-invalidated' })

    actions = {
      action_events:next(),
      action_events:next(),
      action_events:next(),
    }
    newest_health = health:next()
    navigation_generation = navigation:next()
  end, {
    host = host,
    owns_host = false,
    max_seconds_per_turn = 100,
  })

  local initial = advance_until_settled(app)
  assert_eq(initial.state, 'pending')
  assert_truthy(not initial.needs_immediate_resume)

  actions_signal:Fire('light-attack')
  actions_signal:Fire('heavy-attack')
  actions_signal:Fire('dodge')
  health_signal:Fire(100)
  health_signal:Fire(75)
  health_signal:Fire(60)
  navigation_signal:Fire('door-opened')
  navigation_signal:Fire('bridge-lowered')
  navigation_signal:Fire('obstacle-moved')

  local final = advance_until_settled(app)
  assert_eq(final.state, 'settled')
  assert_eq(actions[1], 'light-attack')
  assert_eq(actions[2], 'heavy-attack')
  assert_eq(actions[3], 'dodge')
  assert_eq(newest_health, 60)
  assert_eq(navigation_generation, 3)

  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- Queued events retain every firing; latest subscriptions coalesce a burst.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local queued_signal = FakeSignal.new('RemoteEvent')
  local latest_signal = FakeSignal.new('HealthChanged')
  local q1, q2, q3, newest

  run_scheduled(scheduler, function()
    Roblox.run(function()
      local queued = Roblox.events(queued_signal, { name = 'combat-events' })
      local latest = Roblox.latest(latest_signal, { name = 'latest-health' })

      queued_signal:Fire('hit', 4)
      queued_signal:Fire('parry', 7)
      queued_signal:Fire('dash', 2)
      latest_signal:Fire(98)
      latest_signal:Fire(73)
      latest_signal:Fire(41)

      q1 = { queued:next() }
      q2 = { queued:next() }
      q3 = { queued:next() }
      newest = latest:next()
    end, { host = host, owns_host = false })
  end)

  assert_eq(q1[1], 'hit')
  assert_eq(q1[2], 4)
  assert_eq(q2[1], 'parry')
  assert_eq(q3[1], 'dash')
  assert_eq(newest, 41)
  host:close()
  scheduler:run_until_idle()
end

-- Latest retains only the newest pending value across separate host turns.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local signal = FakeSignal.new('ManaChanged')
  local newest, pending

  run_scheduled(scheduler, function()
    Roblox.run(function()
      local latest = Roblox.latest(signal, { name = 'latest-mana' })
      scheduler.api.delay(1, function()
        signal:Fire(60)
      end)
      scheduler.api.delay(2, function()
        signal:Fire(35)
      end)
      fibers.perform(Sleep.sleep_op(3))
      pending = latest:length()
      newest = latest:next()
    end, { host = host, owns_host = false })
  end)

  assert_eq(pending, 1, 'latest should retain one pending observation')
  assert_eq(newest, 35)
  host:close()
  scheduler:run_until_idle()
end

-- A pulse coalesces several firings and reports the newest logical version.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local heartbeat = FakeSignal.new('Heartbeat')
  local version

  run_scheduled(scheduler, function()
    Roblox.run(function()
      local frames = Roblox.pulse(heartbeat, { name = 'frame-pulse' })
      heartbeat:Fire(1 / 60)
      heartbeat:Fire(1 / 60)
      heartbeat:Fire(1 / 60)
      version = frames:next()
    end, { host = host, owns_host = false })
  end)

  assert_eq(version, 3)
  host:close()
  scheduler:run_until_idle()
end

-- Explicit close retires the owned connection and is idempotent.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local signal = FakeSignal.new('Prompt.Triggered')

  run_scheduled(scheduler, function()
    Roblox.run(function()
      local prompts = Roblox.events(signal)
      assert_eq(signal:connection_count(), 1)
      prompts:close('prompt removed')
      prompts:close('already closed')
      assert_eq(signal:connection_count(), 0)
    end, { host = host, owns_host = false })
  end)
  host:close()
  scheduler:run_until_idle()
end

-- A failed Disconnect leaves the subscription retryable for Closure recovery.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local signal = FakeSignal.new('FragileConnection', { disconnect_failures = 1 })

  run_scheduled(scheduler, function()
    Roblox.run(function()
      local subscription = Roblox.events(signal)
      local ok, err = pcall(function()
        subscription:_disconnect()
      end)
      assert_truthy(not ok, 'first disconnect should fail')
      assert_truthy(tostring(err):match('fake disconnect failure'))
      assert_truthy(subscription:is_connected(), 'failed disconnect should retain the live connection')
      assert_truthy(not subscription:is_closed(), 'failed disconnect should remain unsettled')
      subscription:_disconnect()
      assert_truthy(subscription:is_closed(), 'retry should close the subscription')
      assert_eq(signal:connection_count(), 0)
    end, { host = host, owns_host = false })
  end)
  host:close()
  scheduler:run_until_idle()
end

-- Phase scheduling does not advance merely because an ordinary signal fired.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local heartbeat = FakeSignal.new('RunService.Heartbeat')
  local action = FakeSignal.new('Action')
  local selected

  local app = Roblox.attach(function()
    local actions = Roblox.events(action)
    selected = actions:next()
  end, {
    host = host,
    owns_host = false,
    scheduling = 'phase',
    phase = heartbeat,
  })

  -- The first selected phase admits the root and its subscription.
  heartbeat:Fire(1 / 60)
  scheduler:run_until_idle()
  assert_truthy(not app:is_settled())
  assert_eq(action:connection_count(), 1)

  action:Fire('dodge')
  scheduler:run_until_idle()
  assert_truthy(not app:is_settled(), 'ordinary engine callbacks must not run the solver')

  heartbeat:Fire(1 / 60)
  assert_truthy(
    scheduler:run_until(function()
      return app:is_settled()
    end),
    'phase-driven application did not settle'
  )
  scheduler:run_until_idle()
  assert_eq(selected, 'dodge')
  app:close()
  host:close()
  scheduler:run_until_idle()
end

-- BindToClose publishes cancellation and waits for bounded attached Closure.
do
  local scheduler = FakeTask.new()
  local host = new_host(scheduler)
  local game = FakeGame.new(scheduler.api)
  local result

  scheduler.api.defer(function()
    result = Roblox.try_run(function(scope)
      Roblox.bind_to_close(scope, {
        game = game,
        deadline = 5,
        reason = 'server migration',
      })
      scheduler.api.delay(1, function()
        game:close()
      end)
      fibers.perform(Op.never())
    end, { host = host, owns_host = false })
  end)

  assert_truthy(
    scheduler:run_until(function()
      return result ~= nil
    end),
    'shutdown program did not settle'
  )
  scheduler:run_until_idle()
  assert_truthy(not result.ok, 'root cancellation should be represented as a structured failure')
  assert_truthy(result.report ~= nil, 'shutdown cancellation should retain a scope report')
  host:close()
  scheduler:run_until_idle()
end

print('tests/embedding/test_roblox.lua: ok')
