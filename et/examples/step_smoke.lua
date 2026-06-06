package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local Cell = require('et.resources.cell')

local function assert_eq(a,b,msg) if a ~= b then error((msg or '') .. ' expected '..tostring(b)..' got '..tostring(a),2) end end

-- external loop stepping
local rt = Runtime.new()
local ch = Channel.new('step-ch')
local got, sent
rt:spawn(function() got = rt:perform(ch:get_op(Op)) end, 'r')
rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'x')) end, 's')
local seen_found = false
for i=1,10 do
  local st = rt:step()
  if st.tag == 'found' then seen_found = true end
  if st.tag == 'idle' then break end
end
assert_eq(seen_found, true, 'stepped commit')
assert_eq(got, 'x')
assert_eq(sent, true)

-- bounded solve should be non-mutating on budget exhaustion
local cell = Cell.new(0, 'budget-cell')
local rt2 = Runtime.new()
for i=1,4 do
  rt2:spawn(function()
    rt2:perform(cell:get_op(Op):and_then(function(v)
      return cell:set_op(Op, v + 1)
    end))
  end, 'u'..i)
end
rt2:_pump() -- start all fibres without solving
local st = rt2:step({ max_work = 1 })
assert_eq(st.tag, 'pending', 'budget status')
assert_eq(cell.value, 0, 'pending budget does not mutate')
local committed = false
for i=1,20 do
  local s = rt2:step({ max_work = 1000 })
  if s.tag == 'found' then committed = true end
  if s.tag == 'idle' or s.tag == 'absent' then break end
end
assert_eq(committed, true, 'eventual bounded commit')
assert_eq(cell.value, 4)
print('step smoke: ok')
