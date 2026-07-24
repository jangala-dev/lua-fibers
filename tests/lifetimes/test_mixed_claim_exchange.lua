-- Mixed claim/exchange law: global search must reconsider a participant's
-- branch so a quantitative claim, rendezvous and scalar constraint can close
-- in one committed world.
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
local Counter = require('fibers.resource.counter')
local Rendezvous = require('fibers.resource.rendezvous')
local Scalar = require('fibers.resource.scalar')
local Runtime = require('fibers.runtime')

local rt = Runtime.new()
local c, ch, s = Counter.new({ initial = 0, min = 0 }), Rendezvous.new('claim-backtrack'), Scalar.new(0)
local taken, sent
rt:spawn_raw(function()
  local rows = rt:perform(Op.all({ c:take_op(1), ch:get_op(), s:write_op(2) }))
  taken = rows[1][1]
end, 'taker')
rt:spawn_raw(function()
  sent = rt:perform(Op.choice({
    Op.all({ c:give_op(1), ch:put_op('bad'), s:write_op(1) }):map(function()
      return 'bad'
    end),
    Op.all({ c:give_op(1), ch:put_op('good'), s:write_op(2) }):map(function()
      return 'good'
    end),
  }))
end, 'giver')
local status = rt:run()
assert(status.tag == 'found')
assert(taken == true and sent == 'good' and c.value == 0 and s.value == 2)
print('tests/test_mixed_claim_exchange.lua: ok')
