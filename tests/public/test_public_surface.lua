package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local FibersRuntime = require('fibers.runtime')
local FibersAutoIO = require('fibers.io.auto')
local FibersManualHost = require('fibers.embed.manual')
local FibersPureHost = require('fibers.embed.pure')
local FibersFlow = require('fibers.resource.flow')
local FibersFile = require('fibers.file')
local FibersSocket = require('fibers.socket')
local FibersProcess = require('fibers.process')
local FibersCell = require('fibers.resource.cell')
local FibersMachine = require('fibers.resource.machine')
local FibersCounter = require('fibers.resource.counter')
local FibersFIFO = require('fibers.resource.fifo')
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersLease = require('fibers.resource.lease')
local FibersSignal = require('fibers.resource.signal')
local FibersEventQueue = require('fibers.resource.event_queue')
local FibersClock = require('fibers.resource.clock')
local FibersReadiness = require('fibers.io.readiness')
local FibersLifetime = require('fibers.lifetime')
local FibersEffect = require('fibers.effect')
local FibersTask = require('fibers.task')
local FibersClosure = require('fibers.closure')
local FibersGrant = require('fibers.grant')
local FibersScope = require('fibers.scope')
local FibersRoblox = require('fibers.roblox')
local FibersRobloxHost = require('fibers.roblox.host')
local FibersRobloxSubscription = require('fibers.roblox.subscription')
local FibersChannel = require('fibers.channel')
local FibersMailbox = require('fibers.mailbox')
local FibersPulse = require('fibers.pulse')
local FibersSemaphore = require('fibers.semaphore')
local FibersLatch = require('fibers.latch')
local FibersRefCount = require('fibers.resource.ref_count')
local FibersProtected = require('fibers.protected')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

local function assert_functions(label, value, names)
  for i = 1, #names do
    local name = names[i]
    assert_eq(type(value[name]), 'function', label .. '.' .. name)
  end
end


-- The v1 public module contract is an exact allow-list, not an inventory of
-- every source module. Portable entries must load in the default test profile.
do
  local PublicModules = require('packages.public_modules')
  local seen, previous = {}, nil
  for i = 1, #PublicModules.portable do
    local module = PublicModules.portable[i]
    assert(not seen[module], 'duplicate public module ' .. module)
    assert(previous == nil or previous < module, 'public module allow-list must be sorted')
    seen[module], previous = true, module
    assert(require(module) ~= nil, 'public module failed to load: ' .. module)
  end
  for i = 1, #PublicModules.optional do
    local module = PublicModules.optional[i]
    assert(not seen[module], 'duplicate public module ' .. module)
    assert(previous == nil or previous < module or i == 1, 'optional public module allow-list must be sorted')
    seen[module], previous = true, module
  end

  local deliberately_internal = {
    'fibers.dns',
    'fibers.embed',
    'fibers.io',
    'fibers.io.native_error',
    'fibers.perform',
    'fibers.scope.report',
    'fibers.scope.result',
  }
  for i = 1, #deliberately_internal do
    local module = deliberately_internal[i]
    assert(not seen[module], 'internal or removed module leaked into public allow-list: ' .. module)
  end
end

local function wait_until(cell, pred)
  return cell:wait_until_op(pred)
end

local function modify_when(cell, pred, update)
  return cell:select_op(function(value)
    if pred(value) then
      local new = update(value)
      return cell:write_op(new):map(function()
        return new, value
      end)
    end
  end)
end

-- Compact positive specification of the supported public entry points. Tests
-- below exercise their behaviour; this table deliberately records no discarded
-- aliases or development names.
do
  local surfaces = {
    { 'fibers', fibers, {
      'run', 'try_run', 'perform', 'spawn', 'scope', 'try_scope',
      'mask', 'without_suspension', 'now', 'current_runtime', 'current_scope', 'pcall', 'xpcall',
    } },
    { 'Op', Op, {
      'always', 'never', 'choice', 'named_choice', 'each', 'named_each', 'together', 'named_together',
      'and_then', 'or_else', 'guard', 'map', 'wrap', 'on_defeat', 'emit',
      'is_op',
    } },
    { 'Protected', FibersProtected, { 'pcall', 'xpcall' } },
    { 'Runtime', FibersRuntime, { 'new' } },
    { 'External', External, { 'drive', 'external_feed', 'deliver', 'clear', 'signal', 'events', 'readiness' } },
    { 'Effect', FibersEffect, { 'kind', 'of', 'is_kind', 'is_effect', 'reject', 'is_rejection', 'rejection_reason' } },
    { 'Machine', FibersMachine, {
      'new', 'rule', 'update', 'select', 'select_when',
      'query', 'query_when', 'transition_op',
    } },
    { 'Cell', FibersCell, {
      'new', 'read_op', 'expect_op', 'write_op', 'select_op',
      'wait_until_op', 'match_op',
    } },
    { 'Flow', FibersFlow, { 'new' } },
    { 'File', FibersFile, {
      'open', 'open_op', 'tmpfile', 'tmpfile_op', 'pipe', 'pipe_op',
      'read_all', 'read_all_op', 'write_all', 'write_all_op',
      'mkdir', 'mkdir_op', 'mkdir_p', 'mkdir_p_op', 'rename', 'rename_op',
      'unlink', 'unlink_op', 'submit_open_op', 'submit_read_all_op',
    } },
    { 'Socket', FibersSocket, {
      'listen', 'listen_op', 'listen_inet', 'listen_inet_op',
      'listen_ipv4', 'listen_ipv4_op', 'listen_ipv6', 'listen_ipv6_op',
      'listen_unix', 'listen_unix_op', 'dial', 'dial_op', 'connect',
      'udp', 'udp_op', 'udp_ipv4', 'udp_ipv4_op', 'udp_ipv6', 'udp_ipv6_op',
      'resolve', 'resolve_op', 'resolve_name', 'resolve_name_op', 'dns_resolver',
    } },
    { 'Process', FibersProcess, { 'command', 'shell', 'redirect', 'succeeded', 'describe_status' } },
    { 'AutoIO', FibersAutoIO, {
      'default', 'select', 'available',
      'luajit_linux', 'cffi_linux', 'luaposix', 'nixio',
    } },
    { 'ManualHost', FibersManualHost, { 'new', 'is_supported' } },
    { 'PureHost', FibersPureHost, { 'new' } },
    { 'Roblox', FibersRoblox, {
      'run', 'try_run', 'prepare', 'attach', 'new_host', 'events', 'latest',
      'pulse', 'bind_to_close',
    } },
    { 'Lifetime', FibersLifetime, {
      'define', 'new', 'inert', 'resource', 'task', 'of', 'is', 'require',
    } },
    { 'Closure', FibersClosure, {
      'none', 'running', 'nursery', 'supervisor', 'protocol', 'propagation',
      'combine', 'request_then_wait', 'require_ok', 'is_failure',
    } },
    { 'Grant', FibersGrant, { 'is', 'closed', 'closed_op', 'has_right' } },
    { 'Channel', FibersChannel, { 'new' } },
    { 'Mailbox', FibersMailbox, { 'new', 'reject_newest', 'drop_oldest' } },
    { 'Pulse', FibersPulse, { 'new' } },
    { 'Counter', FibersCounter, { 'new', 'bounded', 'range' } },
    { 'FIFO', FibersFIFO, { 'new' } },
    { 'Rendezvous', FibersRendezvous, { 'new' } },
    { 'Lease', FibersLease, { 'new' } },
    { 'Signal', FibersSignal, { 'new' } },
    { 'EventQueue', FibersEventQueue, { 'new' } },
    { 'Clock', FibersClock, { 'new', 'default' } },
    { 'Readiness', FibersReadiness, { 'new' } },
    { 'Semaphore', FibersSemaphore, { 'new' } },
    { 'Latch', FibersLatch, { 'new' } },
    { 'RefCount', FibersRefCount, { 'new' } },
  }

  for i = 1, #surfaces do
    assert_functions(surfaces[i][1], surfaces[i][2], surfaces[i][3])
  end


  assert_eq(FibersRoblox.Host, FibersRobloxHost, 'Roblox.Host')
  assert_eq(FibersRoblox.Subscription, FibersRobloxSubscription, 'Roblox.Subscription')

  local scope = FibersScope.new():label('public-scope-surface')
  assert_functions('Scope', scope, {
    'spawn_op', 'move_op', 'offer_op', 'accept_op', 'grant_op', 'can_op',
    'has_custody_op',
  })
end

-- The root lifecycle preserves Lua multiple returns, including nil values.
do
  local a, b, c = fibers.run(function()
    return 'root-a', nil, 'root-c'
  end)
  assert_eq(a, 'root-a')
  assert_eq(b, nil)
  assert_eq(c, 'root-c')

  local checked = fibers.try_run(function()
    return 'checked-root'
  end)
  assert_eq(checked.ok, true)
  assert_eq(checked:unpack(), 'checked-root')
end

-- The friendly top-level surface is enough for ordinary rendezvous use.
do
  local ch = FibersRendezvous.new():label('inbox')
  local got
  local st = fibers.try_run(function()
    fibers.spawn(function()
      fibers.perform(ch:put_op('hello'))
    end):label('sender')
    got = fibers.perform(ch:get_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'hello')
end

-- Cells provide transactional facts. Predicates wait directly through wait_until_op.
do
  local cell = FibersCell.new(false):label('flag')
  local seen
  local st = fibers.try_run(function()
    fibers.spawn(function()
      seen = fibers.perform(wait_until(cell, function(v)
        return v == true
      end))
    end):label('waiter')
    fibers.perform(cell:write_op(true))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(seen, true)
end

-- Capacity-like state transitions are ordinary cell composition.
do
  local c = FibersCell.new(1):label('credits')
  local new, old
  local st = fibers.try_run(function()
    new, old = fibers.perform(modify_when(c, function(v)
      return v > 0
    end, function(v)
      return v - 1
    end))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(old, 1)
  assert_eq(new, 0)
  assert_eq(c._location.value, 0)
end

-- A Signal is a public waitable external resource.
do
  local rt = FibersRuntime.new()
  local signal, feed = External.signal(rt)
  signal:label('signal')
  local got
  rt:spawn_raw(function()
    got = rt:perform(signal:wait_op())
  end):label('signal-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  local waits = (st.interests or {})
  assert_eq(st.waits, nil, 'pending status exposes only interests')
  assert_eq(waits[1].kind, 'external')
  feed:set('ready')
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(got, 'ready')
end

do
  local clock = FibersClock.default()
  assert_eq(type(clock.now_op), 'function', 'Clock exposes now_op')
  assert_eq(type(clock.at_op), 'function', 'Clock exposes at_op')
  assert_eq(type(clock.after_op), 'function', 'Clock exposes after_op')
end

-- Clocks are ordinary resources backed by host time.
do
  local now = 0
  local rt = FibersRuntime.new({ host = {
    now = function()
      return now
    end,
  } })
  local ok, observed
  rt:spawn_raw(function()
    ok, observed = rt:perform(Sleep.sleep_op(5))
  end):label('sleeper')
  local st = rt:run()
  assert_status(st, 'pending')
  now = 5
  st = rt:step()
  assert_status(st, 'found')
  assert_eq(ok, true)
  assert_eq(observed, 5)
end

-- Effects are the public form of typed transaction effects.
do
  local discharged = 0
  local Kind = FibersEffect.kind({
    name = 'test-effect',
    key = function(payload)
      return payload.key
    end,
    merge = function(a, _b)
      return a
    end,
    prepare = function(_rt, payload)
      return {
        kind = Kind,
        key = payload.key,
        payload = payload,
        discharge = function()
          discharged = discharged + 1
        end,
      }
    end,
  })
  local effect = FibersEffect.of(Kind, { key = 'once' })
  local st = fibers.try_run(function()
    fibers.perform(Op.emit(effect))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(discharged, 1)
end

-- Structured spawn admits and starts one running Lifetime. Keeping the Task
-- capability must not retain the body closure after closure.
do
  local value, task
  local marker = { retained = false }
  local weak = setmetatable({ marker = marker }, { __mode = 'v' })
  local st = fibers.try_run(function(scope)
    local captured = marker
    marker = nil
    task = fibers.perform(scope:spawn_op(function()
      return captured and 7 or 0
    end, { label = 'child' }))
    value = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(FibersTask.is(task), 'spawn should return a Task capability')
  assert_eq(value, 7)
  for _ = 1, 4 do collectgarbage('collect') end
  assert_eq(weak.marker, nil, 'closed Task should not retain body captures')
end

-- The public resource-toolkit pieces compose in one ordinary program.
do
  local inbox = FibersRendezvous.new():label('atom-kit-inbox')
  local flag = FibersCell.new(false):label('atom-kit-flag')
  local received, joined

  local st = fibers.try_run(function(scope)
    fibers.spawn(function()
      fibers.perform(inbox:put_op('hello'))
      fibers.perform(flag:write_op(true))
    end):label('sender')

    local task = fibers.perform(scope:spawn_op(function()
      local value = fibers.perform(wait_until(flag, function(v) return v == true end))
      return value and 42 or 0
    end, { label = 'worker' }))

    received = fibers.perform(Op.choice(
      inbox:get_op(),
      Sleep.sleep_op(1):map(function() return 'timeout' end)
    ))

    joined = { value = fibers.perform(task:await_op()) }
  end).runtime_status

  assert_status(st, 'found')
  assert_eq(received, 'hello')
  assert_eq(joined.value, 42)
end

-- Body results and complete outcomes preserve Lua multiple returns.
do
  local a, b, c, exit
  local st = fibers.try_run(function(scope)
    local task = fibers.perform(scope:spawn_op(function()
      return 'x', nil, 'z'
    end, { label = 'multi-return-task' }))
    exit = fibers.perform(task:body_result_op())
    a, b, c = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(exit.tag, 'returned')
  assert_eq(a, 'x')
  assert_eq(b, nil)
  assert_eq(c, 'z')
end


print('tests/public/test_public_surface.lua: ok')
