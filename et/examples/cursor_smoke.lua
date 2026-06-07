package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Channel = require('fibers.resources.channel')
local Cell = require('fibers.resources.cell')

local function assert_eq(a,b,msg) if a ~= b then error((msg or '') .. ' expected '..tostring(b)..' got '..tostring(a),2) end end
local function assert_truthy(v,msg) if not v then error(msg or 'expected truthy',2) end end

-- A low budget should preserve a live cursor across pending calls rather than
-- starting algebra search from scratch each tick.
local rt = Runtime.new()
local ch = Channel.new('cursor-rendezvous')
local got, sent
rt:spawn(function() got = rt:perform(ch:get_op(Op)) end, 'r')
rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'x')) end, 's')

local saw_cursor = false
local found = false
for i = 1, 20 do
  local st = rt:step({ max_work = 1 })
  local cs = rt:cursor_stats()
  if cs then saw_cursor = true end
  if st.tag == 'found' then found = true; break end
end
assert_truthy(saw_cursor, 'cursor was retained across bounded pending steps')
assert_truthy(found, 'bounded cursor eventually commits')
assert_eq(got, 'x')
assert_eq(sent, true)

-- Budget exhaustion must not mutate resources before a committable world is found.
local cell = Cell.new(0, 'cursor-cell')
local rt2 = Runtime.new()
for i = 1, 4 do
  rt2:spawn(function()
    rt2:perform(cell:get_op(Op):and_then(function(v)
      return cell:set_op(Op, v + 1)
    end))
  end, 'u'..i)
end
local st = rt2:step({ max_work = 1 })
assert_eq(st.tag, 'pending')
assert_eq(cell.value, 0, 'pending cursor step does not commit')
local commits = 0
for i = 1, 200 do
  st = rt2:step({ max_work = 3 })
  if st.tag == 'found' then commits = commits + 1 end
  if st.tag == 'idle' or st.tag == 'absent' then break end
end
assert_eq(commits, 4)
assert_eq(cell.value, 4)
print('cursor smoke: ok')
