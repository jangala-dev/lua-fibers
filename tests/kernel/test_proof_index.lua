package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')
local Op = require('fibers.op')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function counter(runtime, name)
  return runtime.instrumentation and (runtime.instrumentation.counters[name] or 0) or 0
end

-- A completed Retry is represented by the exact persistent frontier. Re-driving
-- an unchanged runtime must not prove the same absence again.
do
  local rt = Runtime.new({ instrumentation = true })
  local ch = Rendezvous.new():label('persistent-frontier-retry')
  rt:spawn_raw(function() rt:perform(ch:get_op()) end):label('blocked')
  local first = rt:run().tag
  assert(first == 'pending' or first == 'quiescent')
  local calls = counter(rt, 'search_calls')
  local second = rt:run().tag
  assert(second == 'pending' or second == 'quiescent')
  eq(counter(rt, 'search_calls'), calls, 'unchanged retry frontier should avoid search replay')
  local frontier = assert(rt.engine.pending[1]._proof)
  eq(frontier.retry, true)
  eq(frontier.complete, true)
end

-- A new possible supplier invalidates only roots indexed on the affected fact.
do
  local rt = Runtime.new({ instrumentation = true })
  local left, right = Cell.new(0):label('frontier-left'), Cell.new(0):label('frontier-right')
  rt:spawn_raw(function() rt:perform(left:expect_op(1)) end):label('left-waiter')
  rt:spawn_raw(function() rt:perform(right:expect_op(1)) end):label('right-waiter')
  local blocked = rt:run().tag
  assert(blocked == 'pending' or blocked == 'quiescent')
  local left_request, right_request = rt.engine.pending[1], rt.engine.pending[2]
  eq(rt.engine.proof_graph.dirty[left_request] ~= nil, false)
  eq(rt.engine.proof_graph.dirty[right_request] ~= nil, false)
  rt:spawn_raw(function() rt:perform(left:write_op(1)) end):label('left-supplier')
  -- Admission publishes only potential structure; it should invalidate the
  -- compatible left waiter without disturbing the independent right waiter.
  rt:_start_one()
  eq(rt.engine.proof_graph.dirty[left_request] ~= nil, true)
  eq(rt.engine.proof_graph.dirty[right_request] ~= nil, false)
end


-- Committed location changes invalidate Retry through the captured location
-- version; no second dirty-mark traversal is required at commit.
do
  local rt = Runtime.new({ instrumentation = true })
  local cell, observed = Cell.new(0):label('versioned-retry'), nil
  rt:spawn_raw(function() observed = rt:perform(cell:expect_op(1)) end)
  local blocked = rt:run().tag
  assert(blocked == 'pending' or blocked == 'quiescent')
  local snapshot = assert(rt.engine.pending[1]._proof.snapshot)
  eq(snapshot.locations[cell._location], cell._location.version)
  rt:spawn_raw(function() rt:perform(cell:write_op(1)) end)
  rt:run()
  eq(observed, true, 'location version should invalidate completed Retry')
end

-- Residual fallback discards the preferred live wait, but retains a latent
-- membership dependency. A newly admitted compatible participant must reopen
-- the preferred world rather than leave the completed Retry cached.
do
  local rt = Runtime.new({ instrumentation = true })
  local ch = Rendezvous.new():label('persistent-frontier-latent-preferred')
  local got
  rt:spawn_raw(function()
    got = rt:perform(ch:get_op():or_else(Op.never()))
  end):label('latent-receiver')
  local blocked = rt:run().tag
  assert(blocked == 'pending' or blocked == 'quiescent')
  local receiver = rt.engine.pending[1]
  local frontier = assert(receiver._proof)
  assert(frontier.latent.exchanges[ch] and frontier.latent.exchanges[ch].get)
  rt:spawn_raw(function() rt:perform(ch:put_op('primary')) end):label('late-sender')
  eq(rt:run().tag, 'found')
  eq(got, 'primary', 'late compatible participant should invalidate latent Retry')
end

-- Soft bounded yields retain the same coroutine and trail while the versioned
-- frontier remains unchanged.
do
  local rt = Runtime.new({ instrumentation = true })
  local ch = Rendezvous.new():label('persistent-frontier-session')
  rt:spawn_raw(function() rt:perform(ch:get_op()) end):label('receiver')
  rt:spawn_raw(function() rt:perform(ch:put_op('value')) end):label('sender')
  rt:step({ max_work = 1 })
  rt:step({ max_work = 1 })
  rt:step({ max_work = 1 })
  local retained, retained_count
  retained_count = 0
  for _, request in ipairs(rt.engine.pending) do
    if request._retained_search then retained, retained_count = request._retained_search, retained_count + 1 end
  end
  assert(retained, 'bounded search should retain a session')
  eq(retained_count, 1, 'a component should retain at most one active session')
  local thread = retained.thread
  for _ = 1, 20 do
    local status = rt:step({ max_work = 1 })
    if status.tag == 'found' then break end
  end
  assert(coroutine.status(thread) == 'dead' or retained.disposed, 'retained coroutine should finish rather than restart')
  eq(counter(rt, 'searches'), 2, 'each root is still evaluated when needed')
end


-- One intent may carry both a location and an independent resource dependency.
-- Certificate de-duplication must preserve both facts.
do
  local Proof = require('fibers.internal.proof')
  local location, resource = { version = 2 }, { version = 3 }
  local intent = {
    kind = 'transition', request = {}, activation = {}, observed_version = 2,
    spec = { location = location, resource = resource },
  }
  local certificate = Proof.from_intents({ intent })
  local seen_location, seen_resource = false, false
  for i = 1, #certificate[1], 7 do
    local class, object = certificate[1][i + 2], certificate[1][i + 3]
    seen_location = seen_location or class == 'location' and object == location
    seen_resource = seen_resource or class == 'resource' and object == resource
  end
  assert(seen_location and seen_resource, 'one intent must retain distinct location and resource dependencies')
end

print('tests/kernel/test_proof_index.lua: ok')
