package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')
local function assert_eq(a,b,m) if a~=b then error((m or 'assert_eq')..': expected '..tostring(b)..', got '..tostring(a),2) end end
local function assert_status(x,tag,m) if not x or x.tag~=tag then error((m or 'status')..': expected '..tag..', got '..tostring(x and x.tag),2) end end
return function()
  assert_eq(require('et.resources.channel') == Channel, true, 'channel module available under resources')
  local ok = pcall(function() return require('et.channel') end)
  assert_eq(ok, false, 'old et.channel module has been removed')
  local rt = Runtime.new()
  local ch = Channel.new('resources-channel')
  assert_eq(ch.send_op, nil, 'old channel send_op method has been removed')
  assert_eq(ch.recv_op, nil, 'old channel recv_op method has been removed')
  local got
  rt:spawn(function() rt:perform(ch:put_op(Op, 'payload')) end, 'channel-send')
  rt:spawn(function() got = rt:perform(ch:get_op(Op)) end, 'channel-recv')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'payload')
  print('resources/channel tests: ok')
end
