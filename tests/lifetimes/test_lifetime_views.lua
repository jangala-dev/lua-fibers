package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local fibers = require('fibers')
local Lifetime = require('fibers.lifetime')
local Task = require('fibers.task')

local function eq(a, b, msg)
  if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

-- Task and Scope are different capabilities over one node.
do
  local task, body_scope, value
  fibers.run(function(scope)
    task = fibers.perform(scope:spawn_op(function(child)
      body_scope = child
      return 42
    end, 'shared-view'))
    value = fibers.perform(task:await_op())
  end)
  truthy(Task.is(task))
  eq(value, 42)
  eq(task:lifetime(), body_scope:lifetime())
  eq(task:lifetime().cancellation, body_scope:lifetime().cancellation)
  eq(task:lifetime().interrupt, body_scope:lifetime().interrupt)
end

-- Body completion and complete Lifetime closure are distinct facts.
do
  local task, body_exit, outcome
  fibers.run(function(scope)
    task = fibers.perform(scope:spawn_op(function() return 'value' end, 'outcomes'))
    body_exit = fibers.perform(task:body_result_op())
    outcome = fibers.perform(task:outcome_op())
  end)
  eq(body_exit.tag, 'returned')
  truthy(outcome and outcome.ok == true)
  eq(outcome:unpack(), 'value')
end

-- Domain views and execution views may share one node without the node retaining
-- either capability object.
do
  local value = { name = 'domain-view' }
  local node = Lifetime.new('domain-view', { value = value })
  eq(Lifetime.of(value), node)
end

print('tests/lifetimes/test_lifetime_views.lua: ok')
