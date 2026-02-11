-- tests/test_op.lua
--
-- Exercises fibers/op.lua: always, choice, guard, with_nack, and_then, all, bracket.

package.path = '../?.lua;' .. package.path

local sched_mod = require 'fibers.sched'
local new_sched = sched_mod.new or (sched_mod.Scheduler and sched_mod.Scheduler.new)
assert(type(new_sched) == 'function', 'fibers.sched: no constructor found')

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

-- Helper: a one-shot primitive that becomes ready when another fibre signals it.
local function oneshot(value)
  local t = { ready = false, waker = nil, done = false }
  return op.new_primitive(
    function(self, ctx, _)
      if self.done then return self end
      if self.ready then return self end
      self.waker = ctx.waker
      return nil
    end,
    function(self, _)
      self.done = true
      return value
    end,
    function(self, _, _)
      self.waker = nil
    end,
    t
  )
end

-- 1) always: perform returns multi-returns
do
  local sched = new_sched()
  runtime.init(sched)

  local a, b
  runtime.spawn(function()
    a, b = op.perform(op.always(42, 'x'))
  end, 'always-test')

  runtime.main()
  assert(a == 42 and b == 'x')
end

-- 2) choice aborts the losing arm (RB_ABORT)
do
  local sched = new_sched()
  runtime.init(sched)

  local loser_why

  local blocking = op.new_primitive(
    function(self, ctx, _out)
      self.waker = ctx.waker
      return nil
    end,
    function()
      error('blocking.commit should be unreachable', 0)
    end,
    function(_self, _ctx, why)
      loser_why = why
    end
  )

  local winner = op.always('win')

  local got
  runtime.spawn(function()
    got = op.perform(op.choice(blocking, winner))
  end, 'choice-test')

  runtime.main()
  assert(got == 'win')
  assert(loser_why == op._RB_ABORT, 'expected losing arm rollback reason RB_ABORT')
end

-- 3) guard(builder) evaluated once per synchronisation episode
do
  local sched = new_sched()
  runtime.init(sched)

  local count = 0
  local t = oneshot('ok')

  local g = op.guard(function()
    count = count + 1
    return t
  end)

  local got
  runtime.spawn(function()
    got = op.perform(g)
  end, 'guard-waiter')

  runtime.spawn(function()
    assert(t.waker ~= nil, 'expected oneshot to have captured a waker')
    t.ready = true
    t.waker:signal()
  end, 'guard-signal')

  runtime.main()
  assert(got == 'ok')
  assert(count == 1, 'guard builder should have run once')
end

-- 4) with_nack: nack becomes ready when the arm is aborted
do
  local sched = new_sched()
  runtime.init(sched)

  local fired = false

  local arm = op.with_nack(function(nack)
    runtime.spawn(function()
      local ok = op.perform(nack) -- NackWait commits true when fired
      assert(ok == true)
      fired = true
    end, 'nack-waiter')

    return op.never()
  end)

  runtime.spawn(function()
    local r = op.perform(op.choice(op.always('winner'), arm))
    assert(r == 'winner')
  end, 'with-nack-choice')

  runtime.main()
  assert(fired == true, 'expected nack waiter to run after abort')
end

-- 5) and_then: sequences lhs into rhs built from lhs results
do
  local sched = new_sched()
  runtime.init(sched)

  local a, b
  runtime.spawn(function()
    local t = op.always(10, 'p'):and_then(function(x, s)
      return op.always(x + 1, s .. 'q')
    end)
    a, b = op.perform(t)
  end, 'and_then-test')

  runtime.main()
  assert(a == 11 and b == 'pq')
end

-- 6) all: returns per-arm prepared out-buffers (tables with .n)
do
  local sched = new_sched()
  runtime.init(sched)

  local r1, r2
  runtime.spawn(function()
    r1, r2 = op.perform(op.all(op.always(1), op.always(2, 'b')))
  end, 'all-test')

  runtime.main()

  assert(type(r1) == 'table' and type(r2) == 'table')
  assert(r1.n == 1 and r1[1] == 1)
  assert(r2.n == 2 and r2[1] == 2 and r2[2] == 'b')
end

-- 7) bracket: release runs on commit (aborted=false) and on abort rollback (aborted=true)
do
  -- commit path
  local sched = new_sched()
  runtime.init(sched)

  local acquire_n, release_n = 0, 0
  local last_res, last_aborted

  local t = op.bracket(
    function()
      acquire_n = acquire_n + 1
      return { id = acquire_n }
    end,
    function(res, aborted)
      release_n = release_n + 1
      last_res, last_aborted = res, aborted
    end,
    function(_res)
      return op.always('ok')
    end
  )

  local got
  runtime.spawn(function()
    got = op.perform(t)
  end, 'bracket-commit')

  runtime.main()

  assert(got == 'ok')
  assert(acquire_n == 1)
  assert(release_n == 1)
  assert(type(last_res) == 'table' and last_res.id == 1)
  assert(last_aborted == false)

  -- abort path (losing arm in choice)
  local sched2 = new_sched()
  runtime.init(sched2)

  local acquire2, release2 = 0, 0
  local aborted2

  local losing = op.bracket(
    function()
      acquire2 = acquire2 + 1
      return {}
    end,
    function(_, aborted)
      release2 = release2 + 1
      aborted2 = aborted
    end,
    function(_)
      return op.never()
    end
  )

  runtime.spawn(function()
    local r = op.perform(op.choice(op.always('win'), losing))
    assert(r == 'win')
  end, 'bracket-abort-choice')

  runtime.main()

  assert(acquire2 == 1, 'expected acquire to run during choice probe')
  assert(release2 == 1, 'expected release to run on abort rollback')
  assert(aborted2 == true)
end

print('test_op.lua: ok')
