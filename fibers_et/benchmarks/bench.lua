-- Small external benchmark suite for the fibers.
--
-- Run from the repository root with:
--   texlua benchmarks/bench.lua
--
-- Optional scale factor:
--   FIBERS_BENCH_SCALE=5 texlua benchmarks/bench.lua
--
-- These are microbenchmarks intended for relative comparison while refining the
-- implementation.  Each case validates its result before contributing a timing.

local function join_path(prefix, suffix)
  if prefix == '' then return suffix end
  return prefix .. suffix
end

local argv0 = (arg and arg[0]) or ''
local here = argv0:match('^(.*[/\\])[^/\\]*$') or ''
local root = here:gsub('benchmarks[/\\]$', '')

package.path = table.concat({
  join_path(root, '?.lua'),
  join_path(root, '?/init.lua'),
  join_path(root, '?/?.lua'),
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  '../?.lua',
  '../?/init.lua',
  '../?/?.lua',
  package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Channel = require('fibers.channel')
local Cell = require('fibers.cell')
local Ledger = require('fibers.resources.ledger')

local pack_ = table.pack or function(...)
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
  if not value then fail(msg or 'expected truthy value') end
end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag) .. ' (' .. tostring(status and status.reason) .. ')')
  end
  return status.value
end

local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local values = { n = 0 }
  rt:spawn(function()
    values = pack_(rt:perform(op))
  end, 'bench-one-perform')
  local status = rt:run()
  assert_status(status, 'found')
  return values, rt
end

local function run_repeated(reps, fn)
  for _ = 1, reps do fn() end
end

local function env_number(name, default)
  local value = os.getenv(name)
  if value == nil or value == '' then return default end
  value = tonumber(value)
  if not value or value <= 0 then return default end
  return value
end

local scale = env_number('FIBERS_BENCH_SCALE', 1)

local cases = {}

local function add(name, reps, fn)
  cases[#cases + 1] = { name = name, reps = math.max(1, math.floor(reps * scale)), fn = fn }
end

add('simple: always multi-value', 1000, function()
  local values = one_perform(Op.always('a', nil, 'c'))
  assert_eq(values.n, 3)
  assert_eq(values[1], 'a')
  assert_eq(values[2], nil)
  assert_eq(values[3], 'c')
end)

add('simple: map/bind/cell', 400, function()
  local cell = Cell.new(0, 'bench-simple-cell')
  local values = one_perform(
    Op.always(2)
      :map(function(v) return v + 3 end)
      :and_then(function(v)
        return cell:set_op(Op, v):and_then(function()
          return cell:get_op(Op)
        end)
      end)
  )
  assert_eq(values[1], 5)
  assert_eq(cell.value, 5)
end)

add('simple: external rendezvous', 300, function()
  local rt = Runtime.new()
  local ch = Channel.new('bench-simple-rendezvous')
  local got, sent
  rt:spawn(function() got = rt:perform(ch:get_op(Op)) end, 'receiver')
  rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'payload')) end, 'sender')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
  assert_eq(sent, true)
end)

add('simple: tensor internal rendezvous', 250, function()
  local ch = Channel.new('bench-tensor-internal')
  local values = one_perform(Op.tensor({ ch:put_op(Op, 'payload'), ch:get_op(Op) }))
  local rows = values[1]
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 'payload')
end)

add('hard: choice backtracks around conflict', 120, function()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'bench-choice-conflict-cell')
  local rows
  rt:spawn(function()
    rows = rt:perform(Op.tensor({
      cell:set_op(Op, 1):map(function() return 'write-1' end):choice(Op.always('no-write')),
      cell:set_op(Op, 2),
    }))
  end, 'choice-conflict')
  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'no-write')
  assert_eq(rows[2][1], true)
  assert_eq(cell.value, 2)
end)

add('hard: or_else waits for partner backtracking', 100, function()
  local rt = Runtime.new()
  local wanted = Channel.new('bench-or-else-wanted')
  local dead = Channel.new('bench-or-else-dead')
  local receiver, partner
  rt:spawn(function()
    receiver = rt:perform(
      wanted:get_op(Op)
        :map(function(v) return 'primary:' .. tostring(v) end)
        :or_else(Op.always('fallback')))
  end, 'receiver')
  rt:spawn(function()
    partner = rt:perform(Op.choice(dead:put_op(Op, 'dead'), wanted:put_op(Op, 'ok')))
  end, 'partner')
  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:ok')
  assert_eq(partner, true)
end)

add('hard: triple swap with decoy', 80, function()
  local rt = Runtime.new()
  local ab = Channel.new('bench-triple-ab')
  local bc = Channel.new('bench-triple-bc')
  local ca = Channel.new('bench-triple-ca')
  local a, b, c, decoy

  rt:spawn(function()
    a = rt:perform(Op.all({ ab:put_op(Op, 'A'), ca:get_op(Op) }):map(function(rows) return rows[2][1] end))
  end, 'A')
  rt:spawn(function()
    b = rt:perform(Op.all({ bc:put_op(Op, 'B'), ab:get_op(Op) }):map(function(rows) return rows[2][1] end))
  end, 'B')
  rt:spawn(function()
    c = rt:perform(Op.all({ ca:put_op(Op, 'C'), bc:get_op(Op) }):map(function(rows) return rows[2][1] end))
  end, 'C')
  rt:spawn(function()
    decoy = rt:perform(ab:get_op(Op))
  end, 'decoy')

  assert_status(rt:run(), 'found')
  assert_eq(a, 'C')
  assert_eq(b, 'A')
  assert_eq(c, 'B')
  assert_eq(decoy, nil)
end)

add('hard: dependent cell updates', 60, function()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'bench-dependent-cell')
  local returns = {}

  local function op()
    return cell:get_op(Op):and_then(function(old)
      return cell:set_op(Op, old + 1):and_then(function()
        return Op.always(old)
      end)
    end)
  end

  for i = 1, 4 do
    rt:spawn(function()
      returns[#returns + 1] = rt:perform(op())
    end, 'dependent-updater-' .. tostring(i))
  end

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 4)

  local seen = {}
  for i = 1, #returns do seen[returns[i]] = true end
  for i = 0, 3 do assert_truthy(seen[i], 'missing serial old value ' .. tostring(i)) end
  assert_truthy((rt.stats.refreshes or 0) >= 1, 'expected at least one refresh')
end)

add('hard: ledger transfer and settlement', 120, function()
  local ledger = Ledger.new('bench-ledger', 'A')
  local rt = Runtime.new()
  local result
  rt:spawn(function()
    result = rt:perform(
      ledger:transfer_op('A', 'B'):and_then(function()
        return ledger:close_op('B'):and_then(function()
          return ledger:owner_op()
        end)
      end)
    )
  end, 'ledger-transfer-close')
  assert_status(rt:run(), 'found')
  assert_eq(result, 'B')
  assert_eq(ledger.owner, 'B')
  assert_eq(ledger.settled_owner, 'B')
  assert_eq(#rt.published_consequences, 1)
  assert_eq(#rt.published_consequences[1].obligation, 1)
  assert_eq((rt.published_consequences[1].obligation[1].payload or rt.published_consequences[1].obligation[1]).owner, 'B')
end)

io.write('fibers texlua benchmark\n')
io.write('scale: ', tostring(scale), '\n')
io.write(string.format('%-42s %10s %10s %12s\n', 'case', 'reps', 'seconds', 'runs/sec'))
io.write(string.rep('-', 78), '\n')

local grand_reps = 0
local grand_seconds = 0

for i = 1, #cases do
  local case = cases[i]
  collectgarbage('collect')
  local started = os.clock()
  run_repeated(case.reps, case.fn)
  local seconds = os.clock() - started
  grand_reps = grand_reps + case.reps
  grand_seconds = grand_seconds + seconds
  local rate
  if seconds > 0 then rate = case.reps / seconds else rate = 0 end
  io.write(string.format('%-42s %10d %10.4f %12.1f\n', case.name, case.reps, seconds, rate))
end

io.write(string.rep('-', 78), '\n')
io.write(string.format('%-42s %10d %10.4f %12.1f\n', 'total', grand_reps, grand_seconds, grand_seconds > 0 and grand_reps / grand_seconds or 0))
