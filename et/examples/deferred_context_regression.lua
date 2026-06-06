package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local Op = require('et.op')
local Runtime = require('et.runtime')
local Channel = require('et.resources.channel')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_status(st, tag, msg) if not st or st.tag ~= tag then fail((msg or 'status mismatch') .. ': expected ' .. tag .. ', got ' .. tostring(st and st.tag)) end end

-- Deferred bind continuations created before rendezvous closure must retain the
-- original evaluation context.  In particular, a guard and a residual or_else
-- inside the continuation need the fibre attempt and residual environment.
do
  local rt = Runtime.new()
  local ch = Channel.new('deferred-context-search')
  local got, sent
  rt:spawn(function()
    got = rt:perform(ch:get_op(Op):and_then(function(v)
      return Op.guard(function()
        return Op.never():or_else(Op.always('fallback:' .. v))
      end)
    end))
  end, 'receiver')
  rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'x')) end, 'sender')
  local st = rt:run()
  assert_status(st, 'found')
  assert_eq(got, 'fallback:x')
  assert_eq(sent, true)
end

-- The bounded cursor exercises the same deferred path through cursor.lua.
do
  local rt = Runtime.new()
  local ch = Channel.new('deferred-context-cursor')
  local got, sent, st
  rt:spawn(function()
    got = rt:perform(ch:get_op(Op):and_then(function(v)
      return Op.guard(function()
        return Op.never():or_else(Op.always('cursor-fallback:' .. v))
      end)
    end))
  end, 'receiver')
  rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'y')) end, 'sender')
  for _ = 1, 160 do
    st = rt:step({ max_work = 1 })
    if st.tag == 'found' then break end
  end
  assert_status(st, 'found')
  assert_eq(got, 'cursor-fallback:y')
  assert_eq(sent, true)
end

print('deferred context regression: ok')
