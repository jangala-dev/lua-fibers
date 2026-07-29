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
local Facility = require('fibers.resource.authoring')
local Runtime = require('fibers.runtime')
local Petri = require('examples.case_studies.petri.petri')
local Calendar = require('examples.case_studies.calendar.calendar')

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
  assert(fallback.absence_gate ~= nil)

  local producer = rt:spawn_raw(function()
    rt:perform(net:put_op('p', 'primary'))
  end)
  rt:_resume_fiber(producer)
  local producer_id = rt.pending[2].id
  local production = assert(rt:_find_candidate(producer_id))
  assert(rt:_commit_hit(production))
  assert(rt:_commit_hit(fallback) == false)

  local refreshed = assert(rt:_find_candidate(receiver_id))
  assert(refreshed.absence_gate == nil)
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
  assert(fallback.absence_gate ~= nil)

  local canceller = rt:spawn_raw(function()
    rt:perform(cal:cancel_op(1))
  end)
  rt:_resume_fiber(canceller)
  local cancel_id = rt.pending[2].id
  assert(rt:_commit_hit(assert(rt:_find_candidate(cancel_id))))
  assert(rt:_commit_hit(fallback) == false)

  local refreshed = assert(rt:_find_candidate(reserver_id))
  assert(refreshed.absence_gate == nil)
  assert(rt:_commit_hit(refreshed))
  assert(result == 'primary')
end

-- Binary relation witnesses are centrally rechecked. Altering one relation
-- in an odd-cycle witness removes the contradiction and must be rejected.
do
  local Domain = require('fibers.internal.kernel.domain')
  local Rendezvous = require('fibers.resource.rendezvous')
  local count, edges, requests, ids = 5, {}, {}, {}
  for i = 1, count do
    edges[i] = Rendezvous.new('binary-witness-edge-' .. tostring(i))
  end
  for i = 1, count do
    local previous = ((i - 2) % count) + 1
    requests[i] = {
      id = i,
      op = Op.choice(
        Op.each({ edges[i]:put_op(i), edges[previous]:put_op(i) }),
        Op.each({ edges[i]:get_op(), edges[previous]:get_op() })
      ),
    }
    ids[i] = i
  end
  local component = { ids = ids }
  local witness = assert(Domain.exact_binary_relation_failure(requests, component))
  assert(Domain.verify_exact_binary_relation_failure(requests, component, witness))
  local generic = assert(Domain.exact_negative_failure(requests, component))
  assert(generic.kind == witness.kind)
  assert(Domain.verify_exact_negative_failure(requests, component, generic))
  assert(not Domain.verify_exact_negative_failure(requests, component, { kind = 'unknown' }))
  witness.relations[1].parity = 1 - witness.relations[1].parity
  assert(not Domain.verify_exact_binary_relation_failure(requests, component, witness))
end

-- Trusted witness programmes have one cursor form; eager enumerate is not accepted.
do
  local ok, err = pcall(function()
    Facility.witness({
      location = {},
      accepts_supply = false,
      supplies = 'none',
      enumerate = function()
        return {}
      end,
    })
  end)
  assert(ok == false)
  assert(tostring(err):find('requires cursor', 1, true))
end

print('tests/test_witness_validation.lua: ok')
