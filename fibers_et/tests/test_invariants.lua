-- Invariant-level tests for the public algebraic core.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local fibers = require('fibers')
local Runtime = fibers.Runtime
local Op = fibers.Op
local Cell = fibers.Cell
local Channel = fibers.Channel
local Effect = fibers.Effect
local Interrupt = require('fibers.internal.interrupt')
local EffectSet = require('fibers.kernel.effect.set')

local function fail(msg) error(msg, 2) end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end
local function assert_falsy(v, msg) if v then fail((msg or 'expected falsy') .. ': got ' .. tostring(v)) end end

local function run_all(rt)
  local st
  repeat st = rt:run() until st.tag ~= 'found'
  return st
end

-- Plain user tables are opaque values, not solver structure.
do
  local ch = Channel.new('opaque-channel')
  local value = { x = 42, nested = { y = 7 }, [1] = 'array-part' }
  local got
  local rt = Runtime.new()
  rt:spawn_raw(function() rt:perform(ch:put_op(value)) end, 'opaque-put')
  rt:spawn_raw(function() got = rt:perform(ch:get_op()) end, 'opaque-get')
  run_all(rt)
  assert_eq(got, value, 'channel rendezvous preserves table identity')
  assert_eq(got.x, 42, 'channel rendezvous preserves keyed fields')
  assert_eq(got.nested.y, 7, 'channel rendezvous preserves nested user table')
end

do
  local cell = Cell.new(nil, 'opaque-cell')
  local value = { x = 42, nested = { y = 7 }, [1] = 'array-part' }
  local got
  local rt = Runtime.new()
  rt:spawn_raw(function()
    rt:perform(cell:write_op(value))
    got = rt:perform(cell:read_op())
  end, 'opaque-cell-fibre')
  run_all(rt)
  assert_eq(got, value, 'cell stores user table opaquely')
  assert_eq(got.x, 42, 'cell preserves keyed fields')
end

-- Queue Source consumption is journalled: a losing branch does not steal an occurrence.
do
  local rt = Runtime.new()
  local q, feed = rt:queue_source('journalled-source-queue')
  feed:push('event-1')
  local choice_result, next_result
  rt:spawn_raw(function()
    choice_result = rt:perform(fibers.choice(
      Op.always('winner'),
      q:next_op():map(function(v) return 'queue:' .. tostring(v) end)
    ))
    next_result = rt:perform(q:next_op())
  end, 'source-queue-loser')
  run_all(rt)
  assert_eq(choice_result, 'winner', 'left choice wins this deterministic race')
  assert_eq(next_result, 'event-1', 'losing queue branch did not consume occurrence')
end

-- Built-in effect merges are pure: merging does not mutate original payloads.
do
  local token = Interrupt.new('pure-merge-token')
  local first = Effect.interrupt(token, nil)
  local second = Effect.interrupt(token, 'later')
  local set = EffectSet.empty()
  assert_truthy(set:add(first), 'first interrupt effect accepted')
  assert_truthy(set:add(second), 'second interrupt effect merged')
  assert_eq(first.payload.reason, nil, 'merge did not mutate first payload')
  assert_eq(second.payload.reason, 'later', 'merge did not mutate second payload')
  local items = set:items()
  assert_eq(#items, 1, 'duplicate interrupt effects merge')
  assert_eq(items[1].payload.reason, 'later', 'merged payload carries reason')
end

-- Interrupt tokens cannot be raised through the public token surface.
do
  local token = Interrupt.new('capability-safe-token')
  assert_eq(token.raise, nil, 'interrupt token has no public raise method')
  assert_eq(token.clear, nil, 'interrupt token has no public clear method')
  assert_eq(require('fibers').interrupt, nil, 'interrupt module is not part of top-level public surface')
  local rt = Runtime.new()
  rt:spawn_raw(function() rt:perform(Op.emit(Effect.interrupt(token, 'stop'))) end, 'raise-by-effect')
  run_all(rt)
  assert_truthy(token:is_raised(), 'committed interrupt effect raises token')
  assert_eq(token.reason, 'stop', 'committed interrupt effect records reason')
end

-- Host/source mutation is an external driver boundary. It is rejected from
-- effect prepare, which may run speculatively during search.
do
  local BadKind
  BadKind = Effect.kind {
    name = 'bad-prepare-arrival',
    key = function() return 'bad' end,
    merge = function(a, _b) return a end,
    prepare = function(_rt, payload)
      payload.feed:set('illegal')
      return {
        kind = BadKind,
        key = 'bad',
        discharge = function() end,
      }
    end,
  }
  local rt = Runtime.new()
  local _sig, feed = rt:signal('bad-prepare-signal')
  rt:spawn_raw(function() rt:perform(Op.emit(Effect.of(BadKind, { feed = feed }))) end, 'bad-prepare')
  local ok, err = pcall(function() rt:run() end)
  assert_falsy(ok, 'host arrival in prepare is rejected')
  assert_eq(type(err), 'table', 'phase error is structured')
  assert_eq(err.kind, 'phase_error', 'host arrival in prepare is a phase error')
end


-- Region exposes generic claim/settle machinery, not settlement-policy-specific tree methods.
do
  local r = fibers.Region.new('claim-surface')
  assert_eq(type(r.claim_op), 'function', 'Region should expose generic claim_op')
  assert_eq(type(r.settle_claim_op), 'function', 'Region should expose generic settle_claim_op')
  assert_eq(type(r.retire_tree_op), 'nil', 'Region should not expose retire_tree_op')
  assert_eq(type(r.release_tree_op), 'nil', 'Region should not expose release_tree_op')
end

print('tests/test_invariants.lua: ok')
