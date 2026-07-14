local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ')
        .. ': expected '
        .. tostring(expected)
        .. ', got '
        .. tostring(actual),
      2
    )
  end
end

local function truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
  return value
end

local rt = Runtime.new({ search_limit = 1000, resumable_search = true })
if rt.machine_name ~= 'trail' then
  return { status = 'skip', reason = 'retained production session is trail-machine specific' }
end
local ch = Rendezvous.new('reopen-test')
rt:spawn_raw(function()
  rt:perform(ch:get_op())
end, 'blocked-get')
local st = rt:run()
eq(st.tag, 'quiescent')
local focus_id
for id in pairs(rt._search_sessions) do
  focus_id = id
  break
end
truthy(focus_id)
local row = rt:_take_search_session(focus_id)
truthy(row and row.session)
local session = row.session
local ok = session:reopen_retry({
  requests = rt.pending_by_id,
  component = { choice_generation = 77, size = 1, total = 1 },
  search_limit = 9,
})
truthy(ok)
eq(session.state.choice_generation, 77)
eq(session.state.search_limit, 9)
session:discard('test')
