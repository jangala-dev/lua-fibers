package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Witness = require('fibers.resource.witness')
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
  local receiver_request = rt.engine.pending[1]
  local fallback = assert(rt.engine:find_candidate(receiver_request))
  assert(fallback:is_fallback())

  local producer = rt:spawn_raw(function()
    rt:perform(net:put_op('p', 'primary'))
  end)
  rt:_resume_fiber(producer)
  local producer_request = rt.engine.pending[2]
  local production = assert(rt.engine:find_candidate(producer_request))
  assert(production:settle(rt.engine))
  assert(fallback:settle(rt.engine) == false)

  local refreshed = assert(rt.engine:find_candidate(receiver_request))
  assert(not refreshed:is_fallback())
  assert(refreshed:settle(rt.engine))
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
  local reserver_request = rt.engine.pending[1]
  local fallback = assert(rt.engine:find_candidate(reserver_request))
  assert(fallback:is_fallback())

  local canceller = rt:spawn_raw(function()
    rt:perform(cal:cancel_op(1))
  end)
  rt:_resume_fiber(canceller)
  local cancel_request = rt.engine.pending[2]
  assert(assert(rt.engine:find_candidate(cancel_request)):settle(rt.engine))
  assert(fallback:settle(rt.engine) == false)

  local refreshed = assert(rt.engine:find_candidate(reserver_request))
  assert(not refreshed:is_fallback())
  assert(refreshed:settle(rt.engine))
  assert(result == 'primary')
end

-- Trusted witness leaves have one cursor form; eager enumerate is not accepted.
do
  local ok, err = pcall(function()
    Witness.spec({
      location = {},
      accepts_supply = false,
      supplies = 'none',
      enumerate = function()
        return {}
      end,
    })
  end)
  assert(ok == false)
  assert(tostring(err):find('do not accept enumerate', 1, true))
end

do
  local ok, err = pcall(function()
    Witness.spec({
      location = {},
      argument = {},
      cursor = function()
        return {
          next = function()
            return nil
          end,
        }
      end,
    })
  end)
  assert(ok == false)
  assert(tostring(err):find('do not accept argument', 1, true))
end

print('tests/test_witness_validation.lua: ok')
