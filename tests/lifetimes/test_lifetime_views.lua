package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local fibers = require('fibers')
local Lifetime = require('fibers.lifetime')
local Task = require('fibers.task')
local Op = require('fibers.op')
local Cell = require('fibers.resource.cell')

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
    end, { label = 'shared-view' }))
    value = task:await()
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
    task = fibers.perform(scope:spawn_op(function() return 'value' end, { label = 'outcomes' }))
    body_exit = fibers.perform(task:body_result_op())
    outcome = fibers.perform(task:outcome_op())
  end)
  eq(body_exit.tag, 'returned')
  truthy(outcome and outcome.ok == true)
  eq(outcome:unpack(), 'value')
end


-- The user's body exit is published before descendants finish Closure. This is
-- the supervision boundary used to start a replacement while the old Lifetime
-- remains accountable for retained work.
do
  local task, body_exit, outcome_before_release, release
  fibers.run(function(scope)
    release = Cell.new(false):label('body-exit-release')
    task = fibers.perform(scope:spawn_op(function(child)
      child:spawn(function()
        fibers.perform(Cell.wait_until_op(release, function(v) return v == true end))
      end)
      return 'body-finished'
    end, { label = 'body-exit-before-closure' }))

    body_exit = fibers.perform(task:body_result_op():or_else(Op.always('body-not-visible')))
    outcome_before_release = fibers.perform(task:outcome_op():or_else(Op.always('outcome-pending')))
    fibers.perform(release:write_op(true))
    fibers.perform(task:outcome_op())
  end)

  truthy(Task.Exit.is(body_exit), 'body result should be visible while descendant closure is pending')
  eq(body_exit.tag, 'returned')
  eq(body_exit.values[1], 'body-finished')
  eq(outcome_before_release, 'outcome-pending', 'complete Lifetime outcome must remain pending')
end

-- Cancellation after the user body has exited still controls the complete Task
-- Lifetime. It must propagate through the active Scope Closure driver to retained
-- descendants rather than merely interrupting the already-finished body fiber.
do
  local task, child_task, body_exit, child_exit, outcome
  fibers.run(function(scope)
    local hold = Cell.new(false):label('post-body-cancel-hold')
    task = fibers.perform(scope:spawn_op(function(child)
      child_task = child:spawn(function()
        fibers.perform(Cell.wait_until_op(hold, function(v) return v == true end))
      end)
      return 'returned-before-cancel'
    end, { label = 'post-body-cancel-parent' }))

    body_exit = fibers.perform(task:body_result_op())
    local first, reason = fibers.perform(task:request_cancel_op('cancel-during-closure'))
    eq(first, true)
    eq(reason, 'cancel-during-closure')
    child_exit = fibers.perform(child_task:body_result_op())
    outcome = fibers.perform(task:outcome_op())
  end)

  eq(body_exit.tag, 'returned', 'body exit remains the actual user-body result')
  eq(child_exit.tag, 'cancelled', 'retained descendant receives post-body cancellation')
  truthy(outcome ~= nil, 'complete Task Lifetime should resolve after descendant cancellation')
end

-- Domain views and execution views may share one node without the node retaining
-- either capability object.
do
  local value = { name = 'domain-view' }
  local node = Lifetime.new( { value = value }):label('domain-view')
  eq(Lifetime.of(value), node)
end

print('tests/lifetimes/test_lifetime_views.lua: ok')
