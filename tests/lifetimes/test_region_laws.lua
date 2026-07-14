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
local f = require('fibers')
local R = require('fibers.lifetime.region')
local Op = require('fibers.op')
local function fail(m)
  error(m, 2)
end
local function eq(a, b, m)
  if a ~= b then
    fail((m or 'assert') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function ok(v, m)
  if not v then
    fail(m or 'expected truthy')
  end
end
local function st(x, t)
  eq(x and x.tag, t, 'status')
end

-- Cross-region movement is one atomic ownership transition.
do
  local a, b = R.new('pa'), R.new('pb')
  local h = R.handle('ph')
  local moved
  st(
    f.try_run(function()
      f.perform(a:admit_op(h))
      moved = f.perform(a:move_op(h, b))
    end).runtime_status,
    'found'
  )
  eq(moved, h)
  eq(h.owner, b)
  eq(a.owned[h], nil)
  ok(b.owned[h])
end

-- Independent admissions compose, but an independent observation does not use
-- admission as positive supply.
do
  local r = R.new('parallel')
  local a, b = R.handle('a'), R.handle('b')
  local rows, observed
  st(
    f.try_run(function()
      rows = f.perform(Op.all({ r:admit_op(a), r:admit_op(b) }))
    end).runtime_status,
    'found'
  )
  eq(a.owner, r)
  eq(b.owner, r)
  ok(rows)
  local c = R.handle('c')
  st(
    f.try_run(function()
      observed = f.perform(Op.all({ r:admit_op(c), r:owns_op(c) }))
    end).runtime_status,
    'found'
  )
  eq(observed[2][1], false)
  eq(c.owner, r)
end

-- Tree custody moves as a closure; children cannot move independently.
do
  local a, b = R.new('ta'), R.new('tb')
  local p, c = R.handle('p'), R.handle('c')
  local child
  st(
    f.try_run(function()
      f.perform(a:admit_op(R.Owned.tree(p, nil, { R.Owned.inert(c) })))
      child = f.perform(a:move_op(c, b)
        :map(function()
          return 'moved'
        end)
        :or_else(Op.always('blocked')))
      f.perform(a:move_op(p, b))
    end).runtime_status,
    'found'
  )
  eq(child, 'blocked')
  eq(p.owner, b)
  eq(c.owner, b)
end

-- Claim authority is object identity and lifecycle is explicit.
do
  local r = R.new('claim')
  local h = R.handle('h')
  local claim, forged, failed
  st(
    f.try_run(function()
      f.perform(r:admit_op(h))
      claim = f.perform(r:claim_op(h, { reason = 'x' }))
      local fake =
        { _fibers_claim = true, id = claim.id, region = r, root = h, records = claim.records }
      forged = f.perform(r:resolve_claim_op(fake, { kind = 'discharge' })
        :map(function()
          return true
        end)
        :or_else(Op.always(false)))
      f.perform(r:resolve_claim_op(claim, { kind = 'fail', error = 'boom' }))
      failed = f.perform(r:record_op(h))
      f.perform(r:resolve_claim_op(claim, { kind = 'restore' }))
    end).runtime_status,
    'found'
  )
  eq(forged, false)
  eq(failed.phase, 'failed')
  eq(failed.settlement_failed, true)
  eq(h.owner, r)
end

-- Region transitions do not gain same-world supply merely by being in tensor;
-- admit-then-move requires an explicit sequential continuation.
do
  local a, b = R.new('ha'), R.new('hb')
  local h = R.handle('hh')
  st(
    f.try_run(function()
      f.perform(Op.tensor({ a:admit_op(h), a:move_op(h, b) }))
    end).runtime_status,
    'quiescent'
  )
  eq(h.owner, nil)
  st(
    f.try_run(function()
      f.perform(a:admit_op(h):and_then(function()
        return a:move_op(h, b)
      end))
    end).runtime_status,
    'found'
  )
  eq(h.owner, b)
end

print('tests/test_region_laws.lua: ok')
