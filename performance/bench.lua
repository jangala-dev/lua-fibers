-- Comprehensive benchmark suite for fibers.
--
-- Run from the repository root with:
--   lua/luajit/texlua performance/bench.lua
--
-- Useful controls:
--   FIBERS_BENCH_SCALE=5        multiply each case's default iteration count
--   FIBERS_BENCH_REPEATS=5      timed repeats per case; median is reported
--   FIBERS_BENCH_WARMUP=0       disable one warmup run per case
--   FIBERS_BENCH_CASE=pattern   run cases whose "group/name" contains pattern
--   FIBERS_BENCH_FORMAT=csv     text, csv, or json
--
-- The cases are intentionally validating microbenchmarks.  They are intended
-- for relative comparison while optimising the implementation, not for making
-- cross-machine claims.

local function join_path(prefix, suffix)
  if prefix == '' then
    return suffix
  end
  return prefix .. suffix
end

local argv0 = (arg and arg[0]) or ''
local here = argv0:match('^(.*[/\\])[^/\\]*$') or ''
local root = here:gsub('performance[/\\]$', '')

package.path = table.concat({
  join_path(root, 'src/?.lua'),
  join_path(root, 'src/?/init.lua'),
  join_path(root, 'src/?/?.lua'),
  join_path(root, 'reference/?.lua'),
  join_path(root, 'reference/?/init.lua'),
  join_path(root, 'reference/?/?.lua'),
  join_path(root, '?.lua'),
  join_path(root, '?/init.lua'),
  join_path(root, '?/?.lua'),
  package.path,
}, ';')

local fibers = require('fibers')
local Flow = require('fibers.resource.flow')
local Policy = require('fibers.policy')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')
local EventQueue = require('fibers.resource.event_queue')
local Clock = require('fibers.resource.clock')
local Region = require('fibers.region')
local Scope = require('fibers.scope')
local Effect = require('fibers.effect')

local unpack_ = table.unpack or unpack

local function pack_(...)
  return { n = select('#', ...), ... }
end

local function fail(msg)
  error(msg, 2)
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end

local function assert_truthy(value, msg)
  if not value then
    fail(msg or 'expected truthy value')
  end
end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
        .. ' ('
        .. tostring(status and status.reason)
        .. ')'
    )
  end
  return status.value
end

local function run_rt(rt, expected)
  local st
  repeat
    st = rt:run()
  until st.tag ~= 'found'
  if expected then
    assert_status(st, expected)
  end
  return st
end

local function env_number(name, default)
  local value = os.getenv(name)
  if value == nil or value == '' then
    return default
  end
  value = tonumber(value)
  if not value or value < 0 then
    return default
  end
  return value
end

local function env_string(name, default)
  local value = os.getenv(name)
  if value == nil or value == '' then
    return default
  end
  return value
end

local scale = env_number('FIBERS_BENCH_SCALE', 1)
local repeats = math.max(1, math.floor(env_number('FIBERS_BENCH_REPEATS', 3)))
local warmup_enabled = env_number('FIBERS_BENCH_WARMUP', 1) ~= 0
local filter = env_string('FIBERS_BENCH_CASE', arg and arg[1] or '')
local format = env_string('FIBERS_BENCH_FORMAT', 'text')

local cases = {}

local function add(group, name, default_iters, fn)
  cases[#cases + 1] = {
    group = group,
    name = name,
    iters = math.max(1, math.floor(default_iters * scale)),
    fn = fn,
  }
end

local function median(xs)
  table.sort(xs)
  local n = #xs
  if n % 2 == 1 then
    return xs[(n + 1) / 2]
  end
  return (xs[n / 2] + xs[n / 2 + 1]) / 2
end

local function min_value(xs)
  local m = xs[1]
  for i = 2, #xs do
    if xs[i] < m then
      m = xs[i]
    end
  end
  return m
end

local function max_value(xs)
  local m = xs[1]
  for i = 2, #xs do
    if xs[i] > m then
      m = xs[i]
    end
  end
  return m
end

local function should_run(case)
  if not filter or filter == '' then
    return true
  end
  local key = case.group .. '/' .. case.name
  return key:find(filter, 1, true) ~= nil
    or case.group:find(filter, 1, true) ~= nil
    or case.name:find(filter, 1, true) ~= nil
end

local function fmt_num(n)
  return string.format('%.6f', n)
end

local function json_escape(s)
  s = tostring(s)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local BenchEffectKind
BenchEffectKind = Effect.kind({
  name = 'bench-merge',
  order = 75,
  key = function(payload)
    return payload.key
  end,
  merge = function(a, b)
    return { key = a.key, count = (a.count or 1) + (b.count or 1) }
  end,
  prepare = function(_rt, payload)
    return {
      kind = BenchEffectKind,
      key = payload.key,
      payload = payload,
      discharge = function(rt, entry)
        rt.bench_effect_total = (rt.bench_effect_total or 0) + (entry.payload.count or 1)
      end,
    }
  end,
})

local function bench_effect(key, count)
  return Effect.of(BenchEffectKind, { key = key, count = count or 1 })
end

-- --------------------------------------------------------------------------
-- Local option and state cases.
-- --------------------------------------------------------------------------

add('local', 'always perform', 3000, function(n)
  local rt = Runtime.new()
  local sum = 0
  local op = Op.always(1)
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(op)
    end
  end, 'bench-local-always')
  run_rt(rt)
  assert_eq(sum, n)
  return n
end)

add('local', 'map and_then chain', 1500, function(n)
  local rt = Runtime.new()
  local sum = 0
  local op = Op.always(0)
  for _ = 1, 4 do
    op = op:map(function(v)
      return v + 1
    end):and_then(function(v)
      return Op.always(v + 1)
    end)
  end
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(op)
    end
  end, 'bench-local-map-and_then')
  run_rt(rt)
  assert_eq(sum, n * 8)
  return n
end)

add('local', 'wrap post commit', 1500, function(n)
  local rt = Runtime.new()
  local sum = 0
  local op = Op.always(1):wrap(function(v)
    return v + 1
  end)
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(op)
    end
  end, 'bench-local-wrap')
  run_rt(rt)
  assert_eq(sum, n * 2)
  return n
end)

add('scalar', 'serial read write', 1200, function(n)
  local rt = Runtime.new()
  local scalar = Scalar.new(0, 'bench-scalar-serial')
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(scalar:read_op():and_then(function(v)
        return scalar:write_op(v + 1)
      end))
    end
  end, 'bench-scalar-serial')
  run_rt(rt)
  assert_eq(scalar.value, n)
  return n
end)

add('scalar', 'changed wait wake', 400, function(n)
  local rt = Runtime.new()
  local scalar = Scalar.new(0, 'bench-scalar-changed')
  local observed = 0
  rt:spawn_raw(function()
    local snap = rt:perform(scalar:snapshot_op())
    for _ = 1, n do
      local value, version = rt:perform(scalar:changed_op(snap.version))
      observed = value
      snap = { value = value, version = version }
    end
  end, 'bench-scalar-waiter')
  rt:spawn_raw(function()
    for i = 1, n do
      rt:perform(scalar:write_op(i))
    end
  end, 'bench-scalar-writer')
  run_rt(rt)
  assert_eq(observed, n)
  return n
end)

-- --------------------------------------------------------------------------
-- Rendezvous and product cases.
-- --------------------------------------------------------------------------

add('rendezvous', 'external ping pong', 1000, function(n)
  local rt = Runtime.new()
  local ch = Rendezvous.new('bench-ping-pong')
  local sum, sent = 0, 0
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(ch:get_op())
    end
  end, 'bench-ping-recv')
  rt:spawn_raw(function()
    for i = 1, n do
      if rt:perform(ch:put_op(i)) then
        sent = sent + i
      end
    end
  end, 'bench-ping-send')
  run_rt(rt)
  assert_eq(sum, n * (n + 1) / 2)
  assert_eq(sent, n * (n + 1) / 2)
  return n
end)

add('rendezvous', 'tensor internal rendezvous', 700, function(n)
  local rt = Runtime.new()
  local ch = Rendezvous.new('bench-tensor-internal')
  local sum = 0
  rt:spawn_raw(function()
    for i = 1, n do
      local rows = rt:perform(Op.tensor({ ch:put_op(i), ch:get_op() }))
      sum = sum + rows[2][1]
    end
  end, 'bench-tensor-internal')
  run_rt(rt)
  assert_eq(sum, n * (n + 1) / 2)
  return n
end)

add('product', 'all independent scalars', 900, function(n)
  local rt = Runtime.new()
  local a = Scalar.new(0, 'bench-all-a')
  local b = Scalar.new(0, 'bench-all-b')
  local c = Scalar.new(0, 'bench-all-c')
  local seen = 0
  rt:spawn_raw(function()
    for i = 1, n do
      local rows = rt:perform(Op.all({
        a:write_op(i),
        b:read_op(),
        c:write_op(i * 2),
      }))
      if rows[1][1] and rows[3][1] then
        seen = seen + rows[2][1]
      end
    end
  end, 'bench-all-independent')
  run_rt(rt)
  assert_eq(a.value, n)
  assert_eq(c.value, n * 2)
  assert_eq(seen, 0)
  return n
end)

add('product', 'tensor lane and_then external rendezvous', 350, function(n)
  local rt = Runtime.new()
  local internal = Rendezvous.new('bench-and-then-internal')
  local external = Rendezvous.new('bench-and-then-external')
  local sum = 0
  rt:spawn_raw(function()
    for i = 1, n do
      local rows = rt:perform(Op.tensor({
        internal:get_op():and_then(function(v)
          return external:get_op():map(function(x)
            return v + x
          end)
        end),
        internal:put_op(i),
      }))
      sum = sum + rows[1][1]
    end
  end, 'bench-product-main')
  rt:spawn_raw(function()
    for i = 1, n do
      rt:perform(external:put_op(1000 + i))
    end
  end, 'bench-product-partner')
  run_rt(rt)
  assert_eq(sum, n * 1000 + n * (n + 1))
  return n
end)

add('product', 'choice conflict backtrack', 450, function(n)
  local rt = Runtime.new()
  local scalar = Scalar.new(0, 'bench-choice-conflict')
  local wins = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      local rows = rt:perform(Op.tensor({
        scalar
          :write_op(1)
          :map(function()
            return 'write-1'
          end)
          :choice(Op.always('no-write')),
        scalar:write_op(2),
      }))
      if rows[1][1] == 'no-write' and rows[2][1] == true then
        wins = wins + 1
      end
    end
  end, 'bench-choice-conflict')
  run_rt(rt)
  assert_eq(wins, n)
  assert_eq(scalar.value, 2)
  return n
end)

add('product', 'or_else waits for partner', 350, function(n)
  local rt = Runtime.new()
  local wanted = Rendezvous.new('bench-or-else-wanted')
  local dead = Rendezvous.new('bench-or-else-dead')
  local primary = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      local v = rt:perform(wanted
        :get_op()
        :map(function(x)
          return 'primary:' .. x
        end)
        :or_else(Op.always('fallback')))
      if v == 'primary:ok' then
        primary = primary + 1
      end
    end
  end, 'bench-or-else-receiver')
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(Op.choice(dead:put_op('dead'), wanted:put_op('ok')))
    end
  end, 'bench-or-else-partner')
  run_rt(rt)
  assert_eq(primary, n)
  return n
end)

add('product', 'dependent scalar updaters', 180, function(n)
  local total_commits = n * 4
  local rt = Runtime.new()
  local scalar = Scalar.new(0, 'bench-dependent-scalar')
  local returns = {}
  local function update_op()
    return scalar:read_op():and_then(function(old)
      return scalar:write_op(old + 1):and_then(function()
        return Op.always(old)
      end)
    end)
  end
  for i = 1, 4 do
    rt:spawn_raw(function()
      for _ = 1, n do
        local value = rt:perform(update_op())
        returns[#returns + 1] = value
      end
    end, 'bench-dependent-' .. tostring(i))
  end
  run_rt(rt)
  assert_eq(scalar.value, total_commits)
  assert_eq(#returns, total_commits)
  return total_commits
end)

add('product', 'triple swap with decoy', 80, function(n)
  local completed = 0
  for k = 1, n do
    local rt = Runtime.new()
    local ab = Rendezvous.new('bench-triple-ab-' .. tostring(k))
    local bc = Rendezvous.new('bench-triple-bc-' .. tostring(k))
    local ca = Rendezvous.new('bench-triple-ca-' .. tostring(k))
    local a, b, c, decoy
    rt:spawn_raw(function()
      a = rt:perform(Op.all({ ab:put_op('A'), ca:get_op() }):map(function(rows)
        return rows[2][1]
      end))
    end, 'A')
    rt:spawn_raw(function()
      b = rt:perform(Op.all({ bc:put_op('B'), ab:get_op() }):map(function(rows)
        return rows[2][1]
      end))
    end, 'B')
    rt:spawn_raw(function()
      c = rt:perform(Op.all({ ca:put_op('C'), bc:get_op() }):map(function(rows)
        return rows[2][1]
      end))
    end, 'C')
    rt:spawn_raw(function()
      decoy = rt:perform(ab:get_op())
    end, 'decoy')
    run_rt(rt)
    assert_eq(a, 'C')
    assert_eq(b, 'A')
    assert_eq(c, 'B')
    assert_eq(decoy, nil)
    completed = completed + 1
  end
  return completed
end)

-- --------------------------------------------------------------------------
-- External resource and Effect cases.
-- --------------------------------------------------------------------------

add('external', 'queue preloaded consume', 1000, function(n)
  local rt = Runtime.new()
  local q = EventQueue.new('bench-external-events')
  local feed = rt:external_feed(q)
  for i = 1, n do
    feed:set(i)
  end
  local sum = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(q:next_op())
    end
  end, 'bench-external-events-consumer')
  run_rt(rt)
  assert_eq(sum, n * (n + 1) / 2)
  return n
end)

add('external', 'external arrival driver loop', 250, function(n)
  local rt = Runtime.new()
  local q = EventQueue.new('bench-external-driver')
  local feed = rt:external_feed(q)
  local sum = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      sum = sum + rt:perform(q:next_op())
    end
  end, 'bench-external-driver-consumer')
  assert_status(rt:run(), 'pending')
  for i = 1, n do
    feed:set(i)
    assert_status(rt:run(), 'found')
    if i < n then
      assert_status(rt:run(), 'pending')
    end
  end
  assert_eq(sum, n * (n + 1) / 2)
  return n
end)

add('external', 'clock ready', 1000, function(n)
  local now = 1000
  local rt = Runtime.new({ host = {
    now = function()
      return now
    end,
  } })
  local clock = Clock.new('bench-clock')
  local count = 0
  local op = clock:at_op(1)
  rt:spawn_raw(function()
    for _ = 1, n do
      local ok = rt:perform(op)
      if ok then
        count = count + 1
      end
    end
  end, 'bench-clock-ready')
  run_rt(rt)
  assert_eq(count, n)
  return n
end)

add('effect', 'merge duplicate effects', 700, function(n)
  local rt = Runtime.new()
  local lanes = {}
  for i = 1, 8 do
    lanes[i] = Op.emit(bench_effect('same-key', 1))
  end
  local op = Op.tensor(lanes)
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(op)
    end
  end, 'bench-effect-merge')
  run_rt(rt)
  assert_eq(rt.bench_effect_total, n * 8)
  return n * 8
end)

-- --------------------------------------------------------------------------
-- Region, Task, Scope, and policy cases.
-- --------------------------------------------------------------------------

add('region', 'admit owns release', 500, function(n)
  local rt = Runtime.new()
  local region = Region.new('bench-region')
  local ok_count = 0
  rt:spawn_raw(function()
    for i = 1, n do
      local h = Region.handle('handle-' .. tostring(i))
      local admitted = rt:perform(region:admit_op(h))
      local owns = rt:perform(region:owns_op(h))
      local released = rt:perform(region:release_op(h))
      if admitted == h and owns == true and released == h then
        ok_count = ok_count + 1
      end
    end
  end, 'bench-region')
  run_rt(rt)
  assert_eq(ok_count, n)
  assert_eq(region.owned_count, 0)
  return n
end)

add('task', 'scope spawn await settle', 80, function(n)
  local sum = 0
  local r = fibers.try_run(function()
    for i = 1, n do
      local task = fibers.spawn(function()
        return i
      end, { name = 'bench-task-' .. tostring(i) })
      sum = sum + fibers.perform(task:await_op())
    end
  end)
  assert_truthy(r.ok, tostring(r.report or r.reason))
  assert_eq(sum, n * (n + 1) / 2)
  return n
end)

add('policy', 'nursery spawn rendezvous join', 8, function(n)
  local sum = 0
  local r = fibers.try_run(function()
    local ch = Rendezvous.new('bench-nursery-rendezvous')
    for i = 1, n do
      fibers.spawn(function()
        fibers.perform(ch:put_op(i))
      end, 'bench-nursery-child-' .. tostring(i))
    end
    for _ = 1, n do
      sum = sum + fibers.perform(ch:get_op())
    end
  end, { policy = Policy.nursery({ name = 'bench-nursery' }) })
  assert_truthy(r.ok, tostring(r.report or r.reason))
  assert_eq(sum, n * (n + 1) / 2)
  return n
end)

add('scope', 'custody offer', 30, function(n)
  local completed = 0
  for i = 1, n do
    local ok = false
    local r = fibers.try_run(function(root)
      local rt = fibers.current_runtime()
      local request =
        Scope.new('bench-request-' .. tostring(i), { runtime = rt, parent = root, policy = root.policy })
      local supervisor =
        Scope.new('bench-supervisor-' .. tostring(i), { runtime = rt, parent = root, policy = root.policy })
      local resume = Rendezvous.new('bench-resume-' .. tostring(i))
      local task
      request:run(function(req)
        task = fibers.perform(req:spawn_op(function()
          local msg = fibers.perform(resume:get_op())
          return msg
        end, { name = 'bench-session-' .. tostring(i) }))
        local rows = fibers.perform(Op.tensor({
          req:offer_op(task, supervisor),
          supervisor:accept_op(),
        }))
        assert_truthy(rows[2][1].item == task, 'offer receiver did not observe task')
        assert_eq(fibers.perform(req:owns_op(task)), false)
        assert_eq(fibers.perform(supervisor:owns_op(task)), true)
      end)
      supervisor:run(function()
        fibers.perform(resume:put_op('ok'))
        assert_eq(fibers.perform(task:await_op()), 'ok')
      end)
      ok = true
    end)
    assert_truthy(r.ok, tostring(r.report or r.reason))
    assert_truthy(ok, 'custody offer did not finish')
    completed = completed + 1
  end
  return completed
end)

-- --------------------------------------------------------------------------
-- Flow cases.
-- --------------------------------------------------------------------------

add('flow', 'write only unbounded', 400, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-write-only' })
  local inlet = flow:inlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      total = total + rt:perform(inlet:write_op('x'))
    end
  end, 'bench-flow-write-only')
  run_rt(rt)
  assert_eq(total, n)
  local snap
  local rt2 = Runtime.new()
  rt2:spawn_raw(function()
    snap = rt2:perform(flow:inspect_op())
  end, 'inspect')
  run_rt(rt2)
  assert_eq(snap.queued_length, n)
  return n
end)

add('flow', 'sequential write read small', 350, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-seq' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(inlet:write_op('abcd'))
      local bytes = rt:perform(outlet:read_some_op(4))
      total = total + #bytes
    end
  end, 'bench-flow-seq')
  run_rt(rt)
  assert_eq(total, n * 4)
  return n
end)

add('flow', 'tensor write read handoff', 220, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-tensor-handoff' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      local rows = rt:perform(Op.tensor({ inlet:write_op('abcd'), outlet:read_some_op(4) }))
      total = total + rows[1][1] + #rows[2][1]
    end
  end, 'bench-flow-tensor')
  run_rt(rt)
  assert_eq(total, n * 8)
  return n
end)

add('flow', 'capacity release handoff', 180, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-capacity-release', capacity = 4 })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local ok = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(inlet:write_op('abcd'))
      local rows = rt:perform(Op.tensor({ outlet:read_some_op(4), inlet:write_op('wxyz') }))
      if rows[1][1] == 'abcd' and rows[2][1] == 4 then
        ok = ok + 1
      end
      local tail = rt:perform(outlet:read_some_op(4))
      assert_eq(tail, 'wxyz')
    end
  end, 'bench-flow-capacity')
  run_rt(rt)
  assert_eq(ok, n)
  return n
end)

add('flow', 'lease ack return', 220, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-lease' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(inlet:write_op('abcdef'))
      local lease = rt:perform(outlet:lease_some_op(4, 'owner'))
      rt:perform(lease:ack_op(1))
      rt:perform(lease:release_op())
      local bytes = rt:perform(outlet:read_some_op(10))
      total = total + #bytes
    end
  end, 'bench-flow-lease')
  run_rt(rt)
  assert_eq(total, n * 5)
  return n
end)

add('flow', 'read until chunked', 180, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-until' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(inlet:write_op('abc'))
      rt:perform(inlet:write_op('\r'))
      rt:perform(inlet:write_op('\n'))
      local line = rt:perform(outlet:read_until_op('\r\n'))
      total = total + #line
    end
  end, 'bench-flow-until')
  run_rt(rt)
  assert_eq(total, n * 3)
  return n
end)

add('flow', 'peek then drop', 250, function(n)
  local rt = Runtime.new()
  local flow = Flow.new({ name = 'bench-flow-peek-drop' })
  local inlet, outlet = flow:inlet(), flow:outlet()
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(inlet:write_op('abcdef'))
      local p = rt:perform(outlet:peek_exactly_op(3))
      local d = rt:perform(outlet:drop_op(3))
      local r = rt:perform(outlet:read_exactly_op(3))
      total = total + #p + d + #r
    end
  end, 'bench-flow-peek-drop')
  run_rt(rt)
  assert_eq(total, n * 9)
  return n
end)

add('flow', 'splice derived', 140, function(n)
  local rt = Runtime.new()
  local src = Flow.new({ name = 'bench-flow-splice-src' })
  local dst = Flow.new({ name = 'bench-flow-splice-dst' })
  local total = 0
  rt:spawn_raw(function()
    for _ = 1, n do
      rt:perform(src:inlet():write_op('abcdef'))
      local moved = rt:perform(src:outlet():splice_to_op(dst:inlet(), 3))
      local left = rt:perform(src:outlet():read_exactly_op(3))
      local got = rt:perform(dst:outlet():read_exactly_op(3))
      total = total + moved + #left + #got
    end
  end, 'bench-flow-splice')
  run_rt(rt)
  assert_eq(total, n * 9)
  return n
end)

-- --------------------------------------------------------------------------
-- Driver.
-- --------------------------------------------------------------------------

local results = {}

for _, case in ipairs(cases) do
  if should_run(case) then
    if warmup_enabled then
      case.fn(math.max(1, math.floor(case.iters / 20)))
    end
    local samples = {}
    local logical_ops = nil
    for r = 1, repeats do
      collectgarbage('collect')
      local t0 = os.clock()
      local ops = case.fn(case.iters)
      local dt = os.clock() - t0
      samples[#samples + 1] = dt
      logical_ops = ops or case.iters
    end
    results[#results + 1] = {
      group = case.group,
      name = case.name,
      iters = case.iters,
      ops = logical_ops or case.iters,
      median = median(samples),
      min = min_value(samples),
      max = max_value(samples),
      samples = samples,
    }
  end
end

if #results == 0 then
  fail('no benchmark cases matched filter ' .. tostring(filter))
end

if format == 'csv' then
  print('group,name,iters,ops,median_seconds,min_seconds,max_seconds,median_us_per_op')
  for _, r in ipairs(results) do
    print(table.concat({
      r.group,
      r.name,
      tostring(r.iters),
      tostring(r.ops),
      fmt_num(r.median),
      fmt_num(r.min),
      fmt_num(r.max),
      fmt_num((r.median / r.ops) * 1000000),
    }, ','))
  end
elseif format == 'json' then
  print('{')
  print('  "scale": ' .. tostring(scale) .. ',')
  print('  "repeats": ' .. tostring(repeats) .. ',')
  print('  "results": [')
  for i, r in ipairs(results) do
    io.write('    {')
    io.write('"group": ' .. json_escape(r.group) .. ', ')
    io.write('"name": ' .. json_escape(r.name) .. ', ')
    io.write('"iters": ' .. tostring(r.iters) .. ', ')
    io.write('"ops": ' .. tostring(r.ops) .. ', ')
    io.write('"median_seconds": ' .. fmt_num(r.median) .. ', ')
    io.write('"min_seconds": ' .. fmt_num(r.min) .. ', ')
    io.write('"max_seconds": ' .. fmt_num(r.max) .. ', ')
    io.write('"median_us_per_op": ' .. fmt_num((r.median / r.ops) * 1000000))
    io.write('}')
    if i < #results then
      io.write(',')
    end
    io.write('\n')
  end
  print('  ]')
  print('}')
else
  print('fibers benchmark suite')
  print(
    'scale='
      .. tostring(scale)
      .. ' repeats='
      .. tostring(repeats)
      .. (filter ~= '' and (' filter=' .. filter) or '')
  )
  print(string.format('%-12s  %-36s %8s %8s %12s %12s', 'group', 'case', 'iters', 'ops', 'median s', 'us/op'))
  print(string.rep('-', 96))
  for _, r in ipairs(results) do
    print(
      string.format(
        '%-12s  %-36s %8d %8d %12.6f %12.3f',
        r.group,
        r.name,
        r.iters,
        r.ops,
        r.median,
        (r.median / r.ops) * 1000000
      )
    )
  end
end
