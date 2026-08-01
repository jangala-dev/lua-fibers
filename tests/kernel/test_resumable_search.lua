package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Values = require('fibers.internal.values')
local Facility = require('fibers.resource.authoring')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function counter(runtime, name)
  return runtime.instrumentation and (runtime.instrumentation.counters[name] or 0) or 0
end

-- A suspended fallback proof resumes the same guard activations.
do
  local rt = Runtime.new({ instrumentation = true })
  local preferred_calls, fallback_calls, result = 0, 0, nil
  rt:spawn_raw(function()
    result = rt:perform(Op.guard(function()
      preferred_calls = preferred_calls + 1
      return Op.never()
    end):or_else(Op.guard(function()
      fallback_calls = fallback_calls + 1
      return Op.always('fallback')
    end)))
  end, 'resumable-fallback')
  eq(rt:step({ max_work = 1 }).kind, 'started')
  local saw_budget = false
  for _ = 1, 20 do
    local status = rt:step({ max_work = 1 })
    saw_budget = saw_budget or status.kind == 'budget'
    if status.tag == 'found' then break end
  end
  rt:run()
  assert(saw_budget)
  eq(result, 'fallback')
  eq(preferred_calls, 1)
  eq(fallback_calls, 1)
  eq(counter(rt, 'searches'), 1, 'bounded advances should retain one retained search')
end

-- A component retains at most one active retained search and still commits normally.
do
  local rt = Runtime.new({ instrumentation = true })
  local channel = Rendezvous.new('resumable-rendezvous')
  local got, sent
  rt:spawn_raw(function() got = rt:perform(channel:get_op()) end, 'receiver')
  rt:spawn_raw(function() sent = rt:perform(channel:put_op('value')) end, 'sender')
  for _ = 1, 30 do
    if rt:step({ max_work = 1 }).tag == 'found' then break end
  end
  rt:run()
  eq(got, 'value')
  eq(sent, true)
  eq(counter(rt, 'searches'), 2)
end

-- A relevant frontier change invalidates retained speculative state.
do
  local rt = Runtime.new({ instrumentation = true })
  local channel = Rendezvous.new('resumable-invalidation')
  local got
  rt:spawn_raw(function() got = rt:perform(channel:get_op()) end, 'receiver')
  rt:step({ max_work = 1 })
  rt:step({ max_work = 1 })
  local searches_before = counter(rt, 'searches')
  rt:spawn_raw(function() rt:perform(channel:put_op('new')) end, 'late-sender')
  for _ = 1, 30 do
    if rt:step({ max_work = 1 }).tag == 'found' then break end
  end
  rt:run()
  eq(got, 'new')
  assert(counter(rt, 'searches') > searches_before)
  assert(((rt.instrumentation and rt.instrumentation:report()).counters.retained_search_invalidations or 0) >= 1)
end

-- Witness cursors retain their position across bounded yields.
do
  local Journal = require('fibers.internal.kernel.journal')
  local location = Journal.new_location({ name = 'resumable-witness-location', algebra = 'machine', value = 0 })
  local opened, next_calls = 0, 0
  local leaf = Facility.rule.change({
    visibility = 'together',
    supply = 'any',
    location = location,
    cursor = function()
      opened = opened + 1
      local done = false
      return {
        next = function()
          next_calls = next_calls + 1
          if done then return nil end
          done = true
          return Facility.outcome(Facility.patch.machine(1), 'witness')
        end,
      }
    end,
  })
  local rt = Runtime.new()
  local result
  rt:spawn_raw(function() result = rt:perform(Facility.op(leaf)) end, 'resumable-witness')
  for _ = 1, 20 do
    if rt:step({ max_work = 1 }).tag == 'found' then break end
  end
  rt:run()
  eq(result, 'witness')
  eq(opened, 1)
  eq(next_calls, 1)
end

-- Dependencies introduced by the right-hand operation are recruited after the
-- prefix executes, without replaying the whole search on each driver call.
do
  local rt = Runtime.new()
  local prefix = Rendezvous.new('resumable-sequence-prefix')
  local residual = Rendezvous.new('resumable-sequence-residual')
  local got
  rt:spawn_raw(function() got = rt:perform(prefix:get_op():and_then(residual:get_op())) end, 'consumer')
  rt:spawn_raw(function() rt:perform(prefix:put_op(true)) end, 'prefix-supplier')
  rt:spawn_raw(function() rt:perform(residual:put_op('sequence-value')) end, 'residual-supplier')
  for _ = 1, 80 do
    if rt:step({ max_work = 1 }).tag == 'found' then break end
  end
  rt:run()
  eq(got, 'sequence-value')
end

print('tests/kernel/test_resumable_search.lua: ok')
