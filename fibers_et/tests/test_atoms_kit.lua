package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

local function wait_until(scalar, pred)
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if pred(s.value) then return fibers.always(s.value) end
      return scalar:changed_op(s.version):and_then(function() return loop() end)
    end)
  end
  return loop()
end

local function modify_when(scalar, pred, update)
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if not pred(s.value) then
        return scalar:changed_op(s.version):and_then(function() return loop() end)
      end
      local new = update(s.value)
      return scalar:write_op(new):map(function() return new, s.value end)
    end)
  end
  return loop()
end


-- Layer aggregates make the repository structure explicit without changing the
-- ordinary convenience facade.
do
  local atoms = require('fibers.atoms')
  local policy = require('fibers.policy')
  local kernel = require('fibers.kernel')
  assert_eq(atoms.Op, fibers.Op, 'atoms aggregate exports Op')
  assert_eq(atoms.Scalar, fibers.Scalar, 'atoms aggregate exports Scalar')
  assert_eq(atoms.Scalar, fibers.Scalar, 'atoms aggregate exports Scalar')
  assert_eq(atoms.Rendezvous, fibers.Rendezvous, 'atoms aggregate exports Rendezvous')
  assert_eq(atoms.Signal, fibers.Signal, 'atoms aggregate exports Signal')
  assert_eq(atoms.EventQueue, fibers.EventQueue, 'atoms aggregate exports EventQueue')
  assert_eq(atoms.Clock, fibers.Clock, 'atoms aggregate exports Clock')
  assert_eq(atoms.Readiness, fibers.Readiness, 'atoms aggregate exports Readiness')
  assert_eq(atoms.Source, nil, 'Source compatibility aggregate is removed')
  assert_eq(fibers.Source, nil, 'Source compatibility top-level export is removed')
  local source_ok = pcall(require, 'fibers.atoms.source')
  assert_eq(source_ok, false, 'Source compatibility module is removed')
  assert_eq(atoms.Lease, fibers.Lease, 'atoms aggregate exports Lease')
  assert_eq(atoms.Region, fibers.Region, 'atoms aggregate exports Region')
  assert_eq(atoms.Region.Owned, fibers.Region.Owned, 'Owned is part of Region advanced API')
  assert_eq(atoms.Task, nil, 'atoms aggregate does not export Task')
  assert_eq(atoms.Effect, fibers.Effect, 'atoms aggregate exports Effect')
  assert_eq(policy, fibers.policy, 'top-level policy module exports scope policies')
  assert_eq(kernel.Runtime, fibers.Runtime, 'kernel aggregate exports Runtime')
end

-- The friendly top-level surface is enough for ordinary rendezvous use.
do
  local ch = fibers.Rendezvous.new('inbox')
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

-- Scalars provide transactional facts; waiting is expressed with snapshot/changed and Op composition.
do
  local scalar = fibers.Scalar.new(false, 'flag')
  local seen
  local st = fibers.try_run(function()
    fibers.spawn(function()
      seen = fibers.perform(wait_until(scalar, function(v) return v == true end))
    end, 'waiter')
    fibers.perform(scalar:write_op(true))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(seen, true)
end

-- Capacity-like state transitions are ordinary algebra over snapshot/changed/set.
do
  local c = fibers.Scalar.new(1, 'credits')
  local new, old
  local st = fibers.try_run(function()
    new, old = fibers.perform(modify_when(c,
      function(v) return v > 0 end,
      function(v) return v - 1 end
    ))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(old, 1)
  assert_eq(new, 0)
  assert_eq(c.value, 0)
end

-- A Signal is a public waitable external resource.
do
  local rt = fibers.Runtime.new()
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
  local rt = fibers.Runtime.new({ host = { now = function() return now end } })
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
  local Kind = fibers.Effect.kind {
    name = 'test-effect',
    key = function(payload) return payload.key end,
    merge = function(a, _b) return a end,
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
  }
  local effect = fibers.Effect.of(Kind, { key = 'once' })
  local st = fibers.try_run(function()
    fibers.perform(fibers.after_commit(effect))
  end).runtime_status
  assert_status(st, 'found')
  assert_eq(discharged, 1)
end

-- Region and Task make post-commit spawn usable directly.  Keeping the
-- completed task handle should not keep the start closure's captures alive.
do
  local region = fibers.Region.new('root-region')
  local value, task
  local marker = { retained = false }
  local weak = setmetatable({ marker = marker }, { __mode = 'v' })
  local st = fibers.try_run(function()
    local captured = marker
    marker = nil
    task = fibers.perform(fibers.Task.spawn_op(region, function()
      return captured and 7 or 0
    end, 'child'))
    value = fibers.perform(task:await_op())
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(task, 'spawn should return a task handle')
  assert_eq(value, 7)
  for _ = 1, 4 do collectgarbage('collect') end
  assert_eq(weak.marker, nil, 'completed task handle should not retain start closure captures')
end


-- The public atom-kit pieces compose in one ordinary programme.
do
  local inbox = fibers.Rendezvous.new('atom-kit-inbox')
  local flag = fibers.Scalar.new(false, 'atom-kit-flag')
  local region = fibers.Region.new('atom-kit-region')
  local received, joined

  local st = fibers.try_run(function()
    fibers.spawn(function()
      fibers.perform(inbox:put_op('hello'))
      fibers.perform(flag:write_op(true))
    end, 'sender')

    local task = fibers.perform(fibers.Task.spawn_op(region, function()
      local value = fibers.perform(wait_until(flag, function(v) return v == true end))
      return value and 42 or 0
    end, 'worker'))

    received = fibers.perform(fibers.choice(
      inbox:get_op(),
      fibers.sleep_op(1):map(function() return 'timeout' end)
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
  local region = fibers.Region.new('multi-return-region')
  local a, b, c, exit
  local st = fibers.try_run(function()
    local task = fibers.perform(fibers.Task.spawn_op(region, function()
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

print('tests/test_atoms_kit.lua: ok')
