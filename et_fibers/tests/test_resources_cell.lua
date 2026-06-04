package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
local Op = require('et.op')
local Runtime = require('et.runtime')
local Cell = require('et.resources.cell')
local function assert_eq(a,b,m) if a~=b then error((m or 'assert_eq')..': expected '..tostring(b)..', got '..tostring(a),2) end end
local function assert_status(x,tag,m) if not x or x.tag~=tag then error((m or 'status')..': expected '..tag..', got '..tostring(x and x.tag),2) end end
return function()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'effective-cell')
  local a, b, final
  rt:spawn(function() a = rt:perform(cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-a')
  rt:spawn(function() b = rt:perform(cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-b')
  rt:spawn(function() final = rt:perform(cell:get_op(Op)) end, 'cell-get')
  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'contending effective cell updates both complete')
  assert_eq(a, 1)
  assert_eq(b, 2)
  assert_eq(final, 2)
  print('resources/cell tests: ok')
end
