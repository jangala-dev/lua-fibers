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
local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Petri = require('fibers.petri')
local Calendar = require('fibers.calendar')

-- A fallback based on absence of a token must be invalidated by a committed producer.
do
  local rt = Runtime.new()
  local net = Petri.new()
  local receiver_result
  local receiver = rt:spawn_raw(function()
    receiver_result = rt:perform(net:take_op('p'):or_else(Op.always('fallback')))
  end)
  rt:_resume_fiber(receiver)
  local receiver_id = rt.pending[1].id
  local fallback = assert(rt:_find_candidate(receiver_id))
  assert(fallback.negative_guard == true)

  local producer = rt:spawn_raw(function()
    rt:perform(net:put_op('p', 'primary'))
  end)
  rt:_resume_fiber(producer)
  local producer_id = rt.pending[2].id
  local production = assert(rt:_find_candidate(producer_id))
  assert(rt:_commit_hit(production))
  assert(rt:_commit_hit(fallback) == false)

  local refreshed = assert(rt:_find_candidate(receiver_id))
  assert(refreshed.negative_guard == false)
  assert(rt:_commit_hit(refreshed))
  assert(receiver_result == 'primary')
end

-- Calendar absence follows the same validation path.
do
  local rt = Runtime.new()
  local cal = Calendar.new({ { id = 1, start = 0, finish = 5, resources = { 'room' } } })
  local result
  local reserver = rt:spawn_raw(function()
    local r = rt:perform(cal:reserve_at_op({ 'room' }, 0, 5):or_else(Op.always('fallback')))
    result = type(r) == 'table' and 'primary' or r
  end)
  rt:_resume_fiber(reserver)
  local reserver_id = rt.pending[1].id
  local fallback = assert(rt:_find_candidate(reserver_id))
  assert(fallback.negative_guard == true)

  local canceller = rt:spawn_raw(function()
    rt:perform(cal:cancel_op(1))
  end)
  rt:_resume_fiber(canceller)
  local cancel_id = rt.pending[2].id
  assert(rt:_commit_hit(assert(rt:_find_candidate(cancel_id))))
  assert(rt:_commit_hit(fallback) == false)

  local refreshed = assert(rt:_find_candidate(reserver_id))
  assert(refreshed.negative_guard == false)
  assert(rt:_commit_hit(refreshed))
  assert(result == 'primary')
end

print('tests/test_witness_validation.lua: ok')
