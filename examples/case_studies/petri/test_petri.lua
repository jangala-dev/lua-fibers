package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local FibersOp = require('fibers.op')
local FibersPetri = require('examples.case_studies.petri.petri')
local Op, Petri = FibersOp, FibersPetri

local function run(fn)
  fibers.run(fn, { quiet_deadlock = true })
end

local function count(marking, place)
  return #(marking[place] or {})
end

-- Coloured binding, guard, consumption and production.
do
  local net = Petri.new({
    jobs = { { id = 'a', priority = 2 }, { id = 'b', priority = 9 } },
    workers = { 'w1' },
  })
  local start = net:transition({
    inputs = {
      {
        place = 'jobs',
        as = 'job',
        where = function(job)
          return job.priority >= 5
        end,
      },
      { place = 'workers', as = 'worker' },
    },
    produce = function(b)
      return { { place = 'running', value = { job = b.job.id, worker = b.worker } } }
    end,
    result = function(b)
      return b.job.id, b.worker
    end,
  })
  local job, worker
  run(function()
    job, worker = fibers.perform(net:fire_op(start))
  end)
  assert(job == 'b' and worker == 'w1')
  local m = net:marking()
  assert(count(m, 'jobs') == 1 and m.jobs[1].id == 'a')
  assert(count(m, 'workers') == 0 and count(m, 'running') == 1)
end

-- Together permits direct token hand-off; each does not.
do
  local net = Petri.new()
  local rows
  run(function()
    rows = fibers.perform(Op.together({ net:put_op('p', 'x'), net:take_op('p') }))
  end)
  assert(rows[1][1] == true and rows[2][1] == 'x')
  assert(count(net:marking(), 'p') == 0)
end

do
  local net = Petri.new()
  local result
  run(function()
    result =
      fibers.perform(Op.each({ net:put_op('p', 'x'), net:take_op('p') }):or_else(Op.always('fallback')))
  end)
  assert(result == 'fallback')
  assert(count(net:marking(), 'p') == 0)
end

-- Witness alternatives participate in global backtracking.  The first lane
-- initially chooses red, but that prevents the second lane from taking red;
-- the evaluator must reconsider and give the first lane blue.
do
  local net = Petri.new({ p = { 'red', 'blue' } })
  local any = net:transition({
    inputs = { { place = 'p', as = 'x' } },
    result = function(b)
      return b.x
    end,
  })
  local red = net:transition({
    inputs = {
      {
        place = 'p',
        as = 'x',
        where = function(x)
          return x == 'red'
        end,
      },
    },
    result = function(b)
      return b.x
    end,
  })
  local rows
  run(function()
    rows = fibers.perform(Op.each({ net:fire_op(any), net:fire_op(red) }))
  end)
  assert(rows[1][1] == 'blue' and rows[2][1] == 'red')
  assert(count(net:marking(), 'p') == 0)
end

-- A single token remains linear across independent claims.
do
  local net = Petri.new({ p = { 'only' } })
  local result
  run(function()
    result = fibers.perform(Op.each({ net:take_op('p'), net:take_op('p') }):or_else(Op.always('fallback')))
  end)
  assert(result == 'fallback')
  assert(count(net:marking(), 'p') == 1)
end

-- Multi-place firing is one atomic rewrite.
do
  local net = Petri.new({ left = { 2 }, right = { 3 } })
  local add = net:transition({
    inputs = { { place = 'left', as = 'a' }, { place = 'right', as = 'b' } },
    produce = function(b)
      return { sum = { b.a + b.b } }
    end,
    result = function(b)
      return b.a + b.b
    end,
  })
  local value
  run(function()
    value = fibers.perform(net:fire_op(add))
  end)
  assert(value == 5)
  local m = net:marking()
  assert(count(m, 'left') == 0 and count(m, 'right') == 0 and m.sum[1] == 5)
end

-- Immediate fallback is proof-directed over exhausted token bindings.
do
  local net = Petri.new({ p = { 1, 2 } })
  local impossible = net:transition({
    inputs = {
      {
        place = 'p',
        as = 'x',
        where = function(x)
          return x > 10
        end,
      },
    },
  })
  local result
  run(function()
    result = fibers.perform(net:fire_op(impossible):or_else(Op.always('none')))
  end)
  assert(result == 'none' and count(net:marking(), 'p') == 2)
end

print('examples/case_studies/petri/test_petri.lua: ok')
