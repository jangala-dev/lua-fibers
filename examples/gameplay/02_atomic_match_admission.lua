package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Capacity reservation and match-task admission form one committed world. A
-- fallback lobby message is used only after the remaining capacity is proved
-- insufficient.

local fibers = require('fibers')
local Op = require('fibers.op')
local Counter = require('fibers.resource.counter')

local arena_places = Counter.new(4, 'moon-arena-places')
local started = 0
local first_match, second_attempt

local function start_match_op(scope, party_name, party_size)
  return arena_places:take_op(party_size):and_then(function()
    return scope:spawn_op(function()
      started = started + 1
      return party_name .. ' entered the Moon Arena'
    end, { name = 'match:' .. party_name })
  end)
end

fibers.run(function(scope)
  local match_task = fibers.perform(start_match_op(scope, 'Comet Crew', 4))
  first_match = match_task:await()

  local second_status, second_value = fibers.perform(start_match_op(scope, 'Lantern Guild', 2)
    :map(function(task)
      return 'started', task
    end)
    :or_else(Op.always('waiting', 'Lantern Guild joined the waiting room')))

  if second_status == 'started' then
    second_attempt = second_value:await()
  else
    second_attempt = second_value
  end
end)

assert(first_match == 'Comet Crew entered the Moon Arena')
assert(second_attempt == 'Lantern Guild joined the waiting room')
assert(arena_places.value == 0)
assert(started == 1)
print(first_match)
print(second_attempt)
