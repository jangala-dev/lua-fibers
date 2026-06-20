package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Cell = require('fibers.base.cell')
local Runtime = require('fibers.kernel.runtime')
local Net = require('fibers.kernel.transaction_net')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end

local function world_for(rt, op)
  local solver = Net.Solver.new(rt, { [1] = { op = op, fiber = nil, attempt = {} } })
  local out = solver:find_commit_outcome()
  assert_eq(out.tag, 'hit', 'expected local proof world')
  assert_truthy(out.world, 'expected world')
  return out.world
end

-- The transaction net has a deterministic zero-premise corridor for local proof
-- structure.  It still produces an ordinary World and wrap remains a post-commit
-- delivery action.
do
  local rt = Runtime.new()
  local map_count, bind_count, wrap_count = 0, 0, 0
  local op = Op.always(1)
    :map(function(x) map_count = map_count + 1; return x + 1 end)
    :and_then(function(x) bind_count = bind_count + 1; return Op.always(x * 3) end)
    :wrap(function(x) wrap_count = wrap_count + 1; return x + 4 end)

  local world = world_for(rt, op)
  assert_eq(map_count, 1, 'map callback should run during proof reduction')
  assert_eq(bind_count, 1, 'bind callback should run during proof reduction')
  assert_eq(wrap_count, 0, 'wrap callback must not run before commit/delivery')

  local ok, reason = world:commit(rt)
  assert_eq(ok, true, 'local proof world should commit')
  assert_eq(reason, nil)
  assert_eq(wrap_count, 0, 'wrap callback must remain post-commit')

  local vals = world:run_wraps_for(rt, 1)
  assert_eq(vals[1], 10, 'local proof result should pass through wrap at delivery')
  assert_eq(wrap_count, 1, 'wrap callback should run exactly once at delivery')
end

-- If local reduction reaches a genuine resource premise after a bind, the same
-- reduced proof continues in the general net; the bind callback is not rerun by
-- falling back to a fresh search.
do
  local rt = Runtime.new()
  local c = Cell.new(7, 'local-proof-cell')
  local bind_count = 0
  local op = Op.always('go'):and_then(function()
    bind_count = bind_count + 1
    return c:read_op()
  end)

  local world = world_for(rt, op)
  assert_eq(bind_count, 1, 'bind callback should run once before resource proof')
  local ok = world:commit(rt)
  assert_eq(ok, true, 'resource continuation world should commit')
  local vals = world:run_wraps_for(rt, 1)
  assert_eq(vals[1], 7, 'resource continuation should deliver cell value')
  assert_eq(bind_count, 1, 'bind callback must not be rerun by general proof search')
end


-- Guard is search-phase construction, so local proof reduction may run it, but
-- only once for the current attempt.  If it constructs a local proof, the proof
-- is still delivered through the ordinary World path.
do
  local rt = Runtime.new()
  local guard_count = 0
  local op = Op.guard(function()
    guard_count = guard_count + 1
    return Op.always(2):map(function(x) return x + 5 end)
  end)

  local world = world_for(rt, op)
  assert_eq(guard_count, 1, 'guard callback should run during local proof reduction')
  local ok = world:commit(rt)
  assert_eq(ok, true, 'guard-created local proof should commit')
  local vals = world:run_wraps_for(rt, 1)
  assert_eq(vals[1], 7, 'guard-created local proof should deliver its value')
  assert_eq(guard_count, 1, 'guard callback must not be rerun after commit')
end

print('tests/test_local_proof_reduction.lua: ok')
