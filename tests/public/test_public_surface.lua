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
local Effect = require('fibers.effect')
local Sleep = require('fibers.sleep')
local FibersOp = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersHost = require('fibers.host')
local FibersFlow = require('fibers.resource.flow')
local FibersFile = require('fibers.file')
local FibersSocket = require('fibers.socket')
local FibersDNS = require('fibers.dns')
local FibersProcess = require('fibers.process')
local FibersScalar = require('fibers.resource.scalar')
local FibersQueue = require('fibers.resource.queue')
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersLease = require('fibers.resource.lease')
local FibersSignal = require('fibers.resource.signal')
local FibersEventQueue = require('fibers.resource.event_queue')
local FibersClock = require('fibers.resource.clock')
local FibersReadiness = require('fibers.host.readiness')
local FibersLifetime = require('fibers.lifetime')
local FibersEffect = require('fibers.effect')
local FibersTask = require('fibers.task')
local FibersClosure = require('fibers.closure')
local FibersGrant = require('fibers.grant')
local FibersRoblox = require('fibers.roblox')
local FibersRobloxHost = require('fibers.host.roblox')
local FibersRobloxSubscription = require('fibers.roblox.subscription')

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

local function wait_until(scalar, pred)
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if pred(s.value) then
        return Op.always(s.value)
      end
      return scalar:changed_op(s.version):and_then(function()
        return loop()
      end)
    end)
  end
  return loop()
end

local function modify_when(scalar, pred, update)
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if not pred(s.value) then
        return scalar:changed_op(s.version):and_then(function()
          return loop()
        end)
      end
      local new = update(s.value)
      return scalar:write_op(new):map(function()
        return new, s.value
      end)
    end)
  end
  return loop()
end

-- The root module is deliberately a small application language. Specialised
-- facilities and advanced interfaces are imported from their named modules.
do
  local closure = require('fibers.closure')
  assert_eq(type(fibers.run), 'function', 'root exports root lifecycle run')
  assert_eq(type(fibers.try_run), 'function', 'root exports checked root lifecycle run')
  assert_eq(type(fibers.perform), 'function', 'root exports perform')
  assert_eq(type(Op.choice), 'function', 'Op exports option composition')
  assert_eq(type(fibers.spawn), 'function', 'root exports structured spawn')
  assert_eq(type(fibers.now), 'function', 'root exports contextual time')
  assert_eq(type(FibersRuntime.drive), 'function', 'Runtime exports host-driving lifecycle')
  assert_eq(fibers.always, nil, 'root does not export option constructors')
  assert_eq(fibers.choice, nil, 'root does not export option combinators')
  assert_eq(fibers.sleep, nil, 'root does not export Sleep')
  assert_eq(fibers.after_commit, nil, 'root does not export Effect constructors')
  assert_eq(Effect.after_commit, nil, 'Effect.after_commit has been superseded by Op.emit')
  assert_eq(Effect.wake, nil, 'unused wake effects are not public')
  assert_eq(Effect.WakeKind, nil, 'unused wake effect kind is not public')
  assert_eq(fibers.Op, nil, 'root does not export the Op module')
  assert_eq(fibers.Runtime, nil, 'root does not export Runtime')
  assert_eq(fibers.Scalar, nil, 'root does not export Scalar')
  assert_eq(fibers.Stream, nil, 'root does not export Stream')
  assert_eq(fibers.Flow, nil, 'root does not export Flow')
  assert_eq(fibers.host, nil, 'root does not export host adapters')
  assert_eq(fibers.closure, nil, 'root does not export the Closure module')
  assert_eq(require('fibers.closure'), FibersClosure, 'Closure has a direct named module')
  assert_eq(require('fibers.grant'), FibersGrant, 'Grant has a direct named module')
  assert_eq(pcall(require, 'fibers.policy'), false, 'the former Policy module is absent')
  assert_eq(pcall(require, 'fibers.lifetime.settlement'), false, 'Settlement is not a peer public concept')
  assert_eq(pcall(require, 'fibers.lifetime.custody'), false, 'Custody has no facade object')
  assert_eq(pcall(require, 'fibers.lifetime.capture'), false, 'host capture remains private')
  assert_eq(require('fibers.op'), FibersOp, 'Op has a direct named module')
  assert_eq(FibersOp.consequence, nil, 'emit has no long alias')
  assert_eq(require('fibers.resource.scalar'), FibersScalar, 'Scalar has a direct named module')
  assert_eq(require('fibers.resource.flow'), FibersFlow, 'Flow has one canonical resource module')
  assert_eq(require('fibers.resource.queue'), FibersQueue, 'Queue has one canonical resource module')
  assert_eq(require('fibers.file'), FibersFile, 'File facilities have a direct named module')
  assert_eq(type(FibersFile.open), 'function', 'File exposes evented regular-file opening')
  assert_eq(type(FibersFile.tmpfile), 'function', 'File exposes owned temporary files')
  assert_eq(type(FibersFile.submit_open_op), 'function', 'File exposes explicit open submission')
  assert_eq(type(FibersFile.submit_read_all_op), 'function', 'File exposes explicit path-job submission')
  assert_eq(type(FibersFile.read_all), 'function', 'File exposes bounded evented reads')
  assert_eq(type(FibersFile.write_all), 'function', 'File exposes evented writes')
  assert_eq(type(FibersFile.mkdir_p), 'function', 'File exposes evented directory creation')
  assert_eq(require('fibers.socket'), FibersSocket, 'Socket facilities have a direct named module')
  assert_eq(require('fibers.dns'), FibersDNS, 'DNS facilities have a direct named module')
  assert_eq(type(FibersSocket.dns_resolver), 'function', 'Socket exposes the Fibers DNS resolver')
  assert_eq(
    type(FibersSocket.dial_name_op),
    'function',
    'Socket exposes Happy Eyeballs named Dial construction'
  )
  assert_eq(type(FibersSocket.dial_name), 'function', 'Socket exposes direct named Dial construction')
  assert_eq(type(FibersSocket.connect_name), 'function', 'Socket exposes Happy Eyeballs named connection')
  assert_eq(type(FibersSocket.NamedDial), 'table', 'Socket exposes the NamedDial lifecycle')
  assert_eq(type(FibersDNS.new), 'function', 'DNS exposes resolver construction')
  assert_eq(require('fibers.process'), FibersProcess, 'Process facilities have a direct named module')
  assert_eq(fibers.file, nil, 'root does not export file facilities')
  assert_eq(fibers.socket, nil, 'root does not export socket facilities')
  assert_eq(fibers.process, nil, 'root does not export process facilities')
  assert_eq(type(FibersSocket.udp_op), 'function', 'Socket exposes UDP option construction')
  assert_eq(type(FibersSocket.udp), 'function', 'Socket exposes direct UDP construction')
  assert_eq(FibersSocket.datagram_op, nil, 'long UDP option alias is absent')
  assert_eq(FibersSocket.datagram, nil, 'long UDP direct alias is absent')
  assert_eq(FibersSocket.datagram_ipv4_op, nil, 'long IPv4 UDP option alias is absent')
  assert_eq(FibersSocket.datagram_ipv4, nil, 'long IPv4 UDP direct alias is absent')
  assert_eq(FibersSocket.datagram_ipv6_op, nil, 'long IPv6 UDP option alias is absent')
  assert_eq(FibersSocket.datagram_ipv6, nil, 'long IPv6 UDP direct alias is absent')
  assert_eq(fibers.uninterruptible, nil, 'mask has no long alias')
  assert_eq(FibersHost.Reactor, require('fibers.host.reactor'), 'Host exposes the reactor')
  assert_eq(type(FibersHost.roblox), 'function', 'Host exposes the Roblox family constructor')
  assert_eq(FibersRoblox.Host, FibersRobloxHost, 'Roblox integration exposes its host')
  assert_eq(
    FibersRoblox.Subscription,
    FibersRobloxSubscription,
    'Roblox integration exposes owned subscriptions'
  )
  assert_eq(type(FibersRoblox.events), 'function', 'Roblox integration exposes queued signal events')
  assert_eq(type(FibersRoblox.latest), 'function', 'Roblox integration exposes latest-value signal events')
  assert_eq(type(FibersRoblox.pulse), 'function', 'Roblox integration exposes coalesced signal pulses')
  assert_eq(type(FibersRoblox.bind_to_close), 'function', 'Roblox integration exposes root shutdown binding')
  assert_eq(require('fibers.resource.rendezvous'), FibersRendezvous, 'Rendezvous is in the resource toolkit')
  assert_eq(require('fibers.resource.signal'), FibersSignal, 'Signal is an external-fed resource')
  assert_eq(type(FibersLifetime.define), 'function', 'Lifetime defines continuing custody')
  assert_eq(require('fibers.effect'), FibersEffect, 'Effect describes committed obligations')
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
  local ch = FibersRendezvous.new('inbox')
  local got
  local st = fibers.try_run(function()
    fibers.spawn(function()
      fibers.perform(ch:put_op('hello'))
    end, 'sender')
    got = fibers.perform(ch:get_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(got, 'hello')
end

-- Scalars provide transactional facts. Waiting is expressed with snapshot/changed
-- and Op composition.
do
  local scalar = FibersScalar.new(false, 'flag')
  local seen
  local st = fibers.try_run(function()
    fibers.spawn(function()
      seen = fibers.perform(wait_until(scalar, function(v)
        return v == true
      end))
    end, 'waiter')
    fibers.perform(scalar:write_op(true))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(seen, true)
end

-- Capacity-like state transitions are ordinary algebra over snapshot/changed/set.
do
  local c = FibersScalar.new(1, 'credits')
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
  assert_eq(c.value, 0)
end

-- A Signal is a public waitable external resource.
do
  local rt = FibersRuntime.new()
  local signal, feed = rt:signal('signal')
  local got
  rt:spawn_raw(function()
    got = rt:perform(signal:wait_op())
  end, 'signal-waiter')
  local st = rt:run()
  assert_status(st, 'pending')
  local waits = (st.waits or {})
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
  assert_eq(Sleep.now_op, nil, 'Sleep does not duplicate clock observation')
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
  end, 'sleeper')
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
  assert_eq(Kind.order, nil, 'EffectKind has no global numeric ordering field')
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
    end, 'child'))
    value = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(FibersTask.is(task), 'spawn should return a Task capability')
  assert_eq(value, 7)
  for _ = 1, 4 do
    collectgarbage('collect')
  end
  assert_eq(weak.marker, nil, 'closed Task should not retain body captures')
end

-- The public resource-toolkit pieces compose in one ordinary programme.
do
  local inbox = FibersRendezvous.new('atom-kit-inbox')
  local flag = FibersScalar.new(false, 'atom-kit-flag')
  local received, joined

  local st = fibers.try_run(function(scope)
    fibers.spawn(function()
      fibers.perform(inbox:put_op('hello'))
      fibers.perform(flag:write_op(true))
    end, 'sender')

    local task = fibers.perform(scope:spawn_op(function()
      local value = fibers.perform(wait_until(flag, function(v)
        return v == true
      end))
      return value and 42 or 0
    end, 'worker'))

    received = fibers.perform(Op.choice(
      inbox:get_op(),
      Sleep.sleep_op(1):map(function()
        return 'timeout'
      end)
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
    end, 'multi-return-task'))
    exit = fibers.perform(task:body_result_op())
    a, b, c = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(exit.tag, 'returned')
  assert_eq(a, 'x')
  assert_eq(b, nil)
  assert_eq(c, 'z')
end

do
  local Scope = require('fibers.scope')
  local scope = Scope.new('public-lifetime-surface')
  assert(scope.custody == nil, 'Custody is a law, not a facade object')
  assert(type(scope.offer_op) == 'function')
  assert(type(scope.accept_op) == 'function')
  assert(type(scope.grant_op) == 'function')
  assert(type(scope.can_op) == 'function')
  assert(type(scope.custody_op) == 'function')
  assert(type(scope.subtree_op) == 'function')
  assert(scope.borrow_op == nil and scope.authorise_op == nil)
  assert(scope.claim_op == nil, 'close tokens remain private')
end

print('tests/public/test_public_surface.lua: ok')
