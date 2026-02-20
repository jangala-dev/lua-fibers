-- tests/test_op_nested.lua
--
-- A single, deeply nested op test that exercises:
--   * guard (once per episode)
--   * choice (winner/loser abort)
--   * with_nack (nack signalling on abort)
--   * bracket (commit vs abort release)
--   * finally (abort-only cleanup)
--   * and_then (including invalidation restart)
--   * wrap
--   * all (and flattening via wrap)
--
-- Assumes perform() returns multiple values.

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local RB_INVALID = op._RB_INVALID or op.RB_INVALID or 'rb_invalid'

local function out_set1(out, v)
  if not out then return end
  out.n = 1
  out[1] = v
end

-- A "lease" op whose cap can be invalidated across yields.
-- On RB_INVALID rollback, it increments generation and becomes valid again.
local function make_lease()
  local st = { gen = 1, valid = true, invalidations = 0, done = false }

  return op.new_primitive(
    function (self, _ctx, out)
      if self.done then
        out_set1(out, self.gen)
        return true
      end

      if not self.valid then
        return false -- invalid cap (used for validation checks)
      end

      out_set1(out, self.gen)
      return true
    end,

    function (self, _ctx)
      self.done = true
      return self.gen
    end,

    function (self, _ctx, why)
      if why == RB_INVALID then
        self.invalidations = self.invalidations + 1
        self.gen = self.gen + 1
        self.valid = true
      end
    end,

    st
  )
end

-- A blocking one-shot rhs; first use blocks until signalled, then is rolled back as invalid.
local function make_rhs_wait(v)
  local st = { ready = false, waker = nil, done = false, v = v, saw_invalid = false }

  return op.new_primitive(
    function (self, ctx, out)
      if self.done then
        out_set1(out, self.v * 10)
        return true
      end

      if not self.ready then
        self.waker = ctx.waker
        return false
      end

      out_set1(out, self.v * 10)
      return true
    end,

    function (self, _ctx)
      self.done = true
      return self.v * 10
    end,

    function (self, _ctx, why)
      if why == RB_INVALID then
        self.saw_invalid = true
      end
      self.waker = nil
    end,

    st
  )
end

do
  local sched = new_sched()
  runtime.init(sched)

  -- Observability
  local guard_runs = 0

  local outer_acq, outer_rel, outer_aborted = 0, 0, nil
  local a_acq, a_rel, a_aborted = 0, 0, nil
  local b_acq, b_rel, b_aborted = 0, 0, nil

  local nack_fired = false
  local inner_finally_aborted = nil

  local lease = make_lease()
  local rhs1  = nil

  -- Outer bracket (should commit; aborted=false)
  local function acquire_outer() outer_acq = outer_acq + 1; return {} end
  local function release_outer(_res, aborted) outer_rel = outer_rel + 1; outer_aborted = aborted end

  -- Winning arm bracket (should commit; aborted=false)
  local function acquire_a() a_acq = a_acq + 1; return {} end
  local function release_a(_res, aborted) a_rel = a_rel + 1; a_aborted = aborted end

  -- Losing arm bracket (should abort; aborted=true)
  local function acquire_b() b_acq = b_acq + 1; return {} end
  local function release_b(_res, aborted) b_rel = b_rel + 1; b_aborted = aborted end

  local nested =
    op.bracket(acquire_outer, release_outer, function()
      return op.guard(function()
        guard_runs = guard_runs + 1

        local loser =
          op.with_nack(function(nack)
            runtime.spawn(function()
              local ok = op.perform(nack())
              assert(ok == true)
              nack_fired = true
            end, 'nack-waiter')

            return op.bracket(acquire_b, release_b, function()
              return op.never()
            end)
          end)

        local inner_never =
          op.never():finally(function(aborted)
            inner_finally_aborted = aborted
          end)

        local winner =
          op.bracket(acquire_a, release_a, function()
            return lease
              :and_then(function(v)
                if lease.invalidations == 0 then
                  rhs1 = make_rhs_wait(v)     -- blocks on first pass
                  return rhs1
                end
                return op.always(v * 10)      -- ready after invalidation restart
              end)
              :wrap(function(x) return x * 2 end)
              :and_then(function(y)
                return op.all(
                  op.always(y),
                  op.choice(op.always('C'), inner_never)
                ):wrap(function(buf_y, buf_c)
                  return buf_y[1], buf_c[1]
                end)
              end)
          end)

        -- loser first to ensure it participates in probing early
        return op.choice(loser, winner)
      end)
    end)

  local out_y, out_c

  runtime.spawn(function()
    out_y, out_c = op.perform(nested)
  end, 'performer')

  runtime.spawn(function()
    -- The performer must have reached the initial rhs wait and yielded once.
    assert(rhs1 ~= nil, 'expected rhs1 to be created before signaller runs')
    assert(rhs1.waker ~= nil, 'expected rhs1 to have captured ctx.waker')

    -- Invalidate the cached lease cap across the yield, then wake the performer.
    lease.valid = false

    rhs1.ready = true
    rhs1.waker:signal()
  end, 'signaller')

  runtime.main()

  -- Returned values
  assert(out_y == 40, ('expected y=40, got %s'):format(tostring(out_y)))
  assert(out_c == 'C', ('expected c="C", got %s'):format(tostring(out_c)))

  -- Invalidation path was exercised
  assert(lease.invalidations == 1, 'expected exactly one invalidation restart')
  assert(rhs1 and rhs1.saw_invalid == true, 'expected rhs1 rollback with RB_INVALID')

  -- Guard ran once for the whole episode
  assert(guard_runs == 1, 'guard builder should run once per synchronisation episode')

  -- bracket semantics
  assert(outer_acq == 1 and outer_rel == 1 and outer_aborted == false, 'outer bracket should commit')
  assert(a_acq == 1 and a_rel == 1 and a_aborted == false, 'winner bracket should commit')
  assert(b_acq == 1 and b_rel == 1 and b_aborted == true,  'loser bracket should abort')

  -- finally on the losing inner_never in the nested choice
  assert(inner_finally_aborted == true, 'expected inner finally to run with aborted=true')

  -- with_nack signalling on abort
  assert(nack_fired == true, 'expected nack waiter to fire on abort')

  print('test_op_nested.lua: ok')
end
