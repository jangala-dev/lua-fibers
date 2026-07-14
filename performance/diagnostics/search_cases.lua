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
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.scalar')

local function report(name, rt)
  local s = rt.stats
  io.write(
    string.format(
      '%-34s plans=%d search_calls=%d clones=%d commits=%d '
        .. 'validation_failures=%d refreshes=%d fallback_commits=%d\n',
      name,
      s.plans,
      s.search_calls,
      s.state_clones,
      s.commits,
      s.validation_failures,
      s.refreshes,
      s.fallback_commits
    )
  )
end

-- Global cycle with a locally attractive decoy.
do
  local rt = Runtime.new()
  local ab, bc, ca = Rendezvous.new('ab'), Rendezvous.new('bc'), Rendezvous.new('ca')
  rt:spawn_raw(function()
    rt:perform(Op.all({ ab:put_op('A'), ca:get_op() }))
  end)
  rt:spawn_raw(function()
    rt:perform(Op.all({ bc:put_op('B'), ab:get_op() }))
  end)
  rt:spawn_raw(function()
    rt:perform(Op.all({ ca:put_op('C'), bc:get_op() }))
  end)
  rt:spawn_raw(function()
    rt:perform(ab:get_op())
  end)
  assert(rt:run().tag == 'found')
  report('triple swap with decoy', rt)
end

-- Preferred rendezvous requires another participant to abandon its first branch.
do
  local rt = Runtime.new()
  local wanted, dead = Rendezvous.new('wanted'), Rendezvous.new('dead')
  rt:spawn_raw(function()
    rt:perform(wanted:get_op():or_else(Op.always('fallback')))
  end)
  rt:spawn_raw(function()
    rt:perform(Op.choice(dead:put_op('dead'), wanted:put_op('ok')))
  end)
  assert(rt:run().tag == 'found')
  report('or_else partner backtracking', rt)
end

-- A locally preferred choice conflicts when parallel scalar deltas are merged.
do
  local rt = Runtime.new()
  local scalar = Scalar.new(0)
  rt:spawn_raw(function()
    rt:perform(Op.tensor({
      scalar:write_op(1):choice(Op.always('no-write')),
      scalar:write_op(2),
    }))
  end)
  assert(rt:run().tag == 'found')
  report('product conflict backtracking', rt)
end

-- Deferred continuation after an internal rendezvous introduces a further partner.
do
  local rt = Runtime.new()
  local inside, outside = Rendezvous.new('inside'), Rendezvous.new('outside')
  rt:spawn_raw(function()
    rt:perform(Op.tensor({
      inside:get_op():and_then(function()
        return outside:get_op()
      end),
      inside:put_op('x'),
    }))
  end)
  rt:spawn_raw(function()
    rt:perform(outside:put_op('y'))
  end)
  assert(rt:run().tag == 'found')
  report('deferred internal then external', rt)
end
