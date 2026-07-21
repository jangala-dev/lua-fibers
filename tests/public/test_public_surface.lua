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
local FibersOp = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local FibersHost = require('fibers.host')
local FibersFlow = require('fibers.flow')
local FibersFile = require('fibers.file')
local FibersSocket = require('fibers.socket')
local FibersProcess = require('fibers.process')
local FibersScalar = require('fibers.scalar')
local FibersRendezvous = require('fibers.resource.rendezvous')
local FibersLease = require('fibers.resource.lease')
local FibersSignal = require('fibers.external.signal')
local FibersEventQueue = require('fibers.external.event_queue')
local FibersClock = require('fibers.external.clock')
local FibersReadiness = require('fibers.external.readiness')
local FibersRegion = require('fibers.lifetime.region')
local FibersEffect = require('fibers.lifetime.effect')
local FibersTask = require('fibers.task')
local FibersPhase = require('experiments.phase')
local FibersPolicy = require('fibers.policy')

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
        return fibers.always(s.value)
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
  local policy = require('fibers.policy')
  assert_eq(type(fibers.run), 'function', 'root exports run')
  assert_eq(type(fibers.perform), 'function', 'root exports perform')
  assert_eq(type(fibers.choice), 'function', 'root exports option composition')
  assert_eq(type(fibers.spawn), 'function', 'root exports structured spawn')
  assert_eq(fibers.Op, nil, 'root does not export the Op module')
  assert_eq(fibers.Runtime, nil, 'root does not export Runtime')
  assert_eq(fibers.Scalar, nil, 'root does not export Scalar')
  assert_eq(fibers.Region, nil, 'root does not export Region')
  assert_eq(fibers.Stream, nil, 'root does not export Stream')
  assert_eq(fibers.Flow, nil, 'root does not export Flow')
  assert_eq(fibers.host, nil, 'root does not export host adapters')
  assert_eq(fibers.policy, nil, 'root does not export policy modules')
  assert_eq(policy, FibersPolicy, 'policy remains available as a named module')
  assert_eq(require('fibers.op'), FibersOp, 'Op has a direct named module')
  assert_eq(FibersOp.consequence, nil, 'emit has no long alias')
  assert_eq(require('fibers.scalar'), FibersScalar, 'Scalar has a direct named module')
  assert_eq(require('fibers.flow'), FibersFlow, 'Flow has a direct named module')
  assert_eq(require('fibers.file'), FibersFile, 'File facilities have a direct named module')
  assert_eq(type(FibersFile.open), 'function', 'File exposes evented regular-file opening')
  assert_eq(type(FibersFile.tmpfile), 'function', 'File exposes owned temporary files')
  assert_eq(type(FibersFile.submit_open_op), 'function', 'File exposes explicit open submission')
  assert_eq(type(FibersFile.submit_read_all_op), 'function', 'File exposes explicit path-job submission')
  assert_eq(type(FibersFile.read_all), 'function', 'File exposes bounded evented reads')
  assert_eq(type(FibersFile.write_all), 'function', 'File exposes evented writes')
  assert_eq(type(FibersFile.mkdir_p), 'function', 'File exposes evented directory creation')
  assert_eq(require('fibers.socket'), FibersSocket, 'Socket facilities have a direct named module')
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
  assert_eq(require('fibers.resource.rendezvous'), FibersRendezvous, 'Rendezvous is in the resource toolkit')
  assert_eq(require('fibers.external.signal'), FibersSignal, 'Signal is an external fact')
  assert_eq(require('fibers.lifetime.region'), FibersRegion, 'Region is lifetime machinery')
  assert_eq(require('fibers.lifetime.effect'), FibersEffect, 'Effect is lifetime machinery')
  assert_eq(FibersRegion._ledger, nil, 'Region does not export its shared ledger')
  assert_eq(FibersRegion._clone_ledger, nil, 'Region does not export ledger cloning')
  assert_truthy(type(FibersPhase.new) == 'function', 'Phase remains available only as an experiment')
  local atoms_ok = pcall(require, 'fibers.atoms')
  local kernel_ok = pcall(require, 'fibers.kernel')
  assert_eq(atoms_ok, false, 'the obsolete atoms aggregate is removed')
  assert_eq(kernel_ok, false, 'the trusted kernel aggregate is removed')
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
    ok, observed = rt:perform(fibers.sleep_op(5))
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
  local effect = FibersEffect.of(Kind, { key = 'once' })
  local st = fibers.try_run(function()
    fibers.perform(fibers.after_commit(effect))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(discharged, 1)
end

-- Region and Task make post-commit spawn usable directly.  Keeping the
-- completed task handle should not keep the start closure's captures alive.
do
  local region = FibersRegion.new('root-region')
  local value, task
  local marker = { retained = false }
  local weak = setmetatable({ marker = marker }, { __mode = 'v' })
  local st = fibers.try_run(function()
    local captured = marker
    marker = nil
    task = fibers.perform(FibersTask.spawn_op(region, function()
      return captured and 7 or 0
    end, 'child'))
    value = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(task, 'spawn should return a task handle')
  assert_eq(value, 7)
  for _ = 1, 4 do
    collectgarbage('collect')
  end
  assert_eq(weak.marker, nil, 'completed task handle should not retain start closure captures')
end

-- The public resource-toolkit pieces compose in one ordinary programme.
do
  local inbox = FibersRendezvous.new('atom-kit-inbox')
  local flag = FibersScalar.new(false, 'atom-kit-flag')
  local region = FibersRegion.new('atom-kit-region')
  local received, joined

  local st = fibers.try_run(function()
    fibers.spawn(function()
      fibers.perform(inbox:put_op('hello'))
      fibers.perform(flag:write_op(true))
    end, 'sender')

    local task = fibers.perform(FibersTask.spawn_op(region, function()
      local value = fibers.perform(wait_until(flag, function(v)
        return v == true
      end))
      return value and 42 or 0
    end, 'worker'))

    received = fibers.perform(fibers.choice(
      inbox:get_op(),
      fibers.sleep_op(1):map(function()
        return 'timeout'
      end)
    ))

    local value = fibers.perform(task:await_op())
    joined = { value = value }
  end).runtime_status

  assert_status(st, 'found')
  assert_eq(received, 'hello')
  assert_eq(joined.value, 42)
end

-- Task await unwraps Exit and preserves Lua multiple-return values.
do
  local region = FibersRegion.new('multi-return-region')
  local a, b, c, exit
  local st = fibers.try_run(function()
    local task = fibers.perform(FibersTask.spawn_op(region, function()
      return 'x', nil, 'z'
    end, 'multi-return-task'))
    exit = fibers.perform(task:exit_op())
    a, b, c = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(exit.tag, 'returned')
  assert_eq(a, 'x')
  assert_eq(b, nil)
  assert_eq(c, 'z')
end

print('tests/public/test_public_surface.lua: ok')
