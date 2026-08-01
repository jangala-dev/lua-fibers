package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?/init.lua',
  package.path,
}, ';')

local Ref = require('reference.evaluator')
local RefOp = Ref.Op
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')

local unpack_ = table.unpack or unpack

local function eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function ref_each(lanes)
  return RefOp.each(unpack_(lanes))
end

local function reference_lanes(resource, puts, gets)
  local lanes = {}
  for i = 1, puts do
    lanes[#lanes + 1] = RefOp.put(resource, i)
  end
  for _ = 1, gets do
    lanes[#lanes + 1] = RefOp.get(resource)
  end
  return lanes
end

local function production_lanes(channel, puts, gets)
  local lanes = {}
  for i = 1, puts do
    lanes[#lanes + 1] = channel:put_op(i)
  end
  for _ = 1, gets do
    lanes[#lanes + 1] = channel:get_op()
  end
  return lanes
end

local function reference_result(op, label)
  local result = Ref.evaluate(op, { max_steps = 200000 })
  eq(result.tag, 'Hit', label .. ' reference search should decide the finite world')
  local value = result.worlds[1].result[1]
  for i = 2, #result.worlds do
    eq(result.worlds[i].result[1], value, label .. ' reference worlds disagree on outcome')
  end
  return value
end

local function production_result(op, label)
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 20000 })
  local value
  runtime:spawn_raw(function()
    value = runtime:perform(op)
  end, label)
  local status = runtime:run()
  eq(status and status.tag, 'found', label .. ' production search should decide the finite world')
  return value
end

-- A complete single-resource frontier is feasible exactly when its role counts
-- balance. This checks the implicit-complete representation used by the lazy
-- frontier implementation.
for puts = 1, 4 do
  for gets = 1, 4 do
    local resource = 'reference-complete-' .. puts .. '-' .. gets
    local expected = puts == gets and 'preferred' or 'fallback'
    local reference = RefOp.together(unpack_(reference_lanes(resource, puts, gets)))
      :map(function()
        return 'preferred'
      end)
      :or_else(RefOp.always('fallback'))

    local channel = Rendezvous.new(resource)
    local production = Op.together(production_lanes(channel, puts, gets))
      :map(function()
        return 'preferred'
      end)
      :or_else(Op.always('fallback'))

    eq(reference_result(reference, resource), expected, resource .. ' reference result')
    eq(production_result(production, resource), expected, resource .. ' production result')
  end
end

-- Two independent roots enclosed by an interacting product form a constrained
-- bipartite graph. A complete matching exists exactly when each root's puts
-- cover the other root's gets. The generated cases include balanced but
-- Hall-deficient frontiers, not merely role-count imbalance.
local generated = 0
for a_puts = 0, 3 do
  for a_gets = 0, 3 do
    for b_puts = 0, 3 do
      for b_gets = 0, 3 do
        local total = a_puts + a_gets + b_puts + b_gets
        if total <= 8 and a_puts + a_gets > 0 and b_puts + b_gets > 0 then
          generated = generated + 1
          local label = table.concat({ 'reference-constrained', a_puts, a_gets, b_puts, b_gets }, '-')
          local expected = a_puts == b_gets and b_puts == a_gets and 'preferred' or 'fallback'

          local reference = RefOp.together(
            ref_each(reference_lanes(label, a_puts, a_gets)),
            ref_each(reference_lanes(label, b_puts, b_gets))
          )
            :map(function()
              return 'preferred'
            end)
            :or_else(RefOp.always('fallback'))

          local channel = Rendezvous.new(label)
          local production = Op.together({
            Op.each(production_lanes(channel, a_puts, a_gets)),
            Op.each(production_lanes(channel, b_puts, b_gets)),
          })
            :map(function()
              return 'preferred'
            end)
            :or_else(Op.always('fallback'))

          eq(reference_result(reference, label), expected, label .. ' reference result')
          eq(production_result(production, label), expected, label .. ' production result')
        end
      end
    end
  end
end
eq(generated, 190, 'generated constrained frontier count')

-- The production bulk matcher proposes one matching but must retain exhaustive
-- search when a continuation rejects it. The reference evaluator has no bulk
-- branch and therefore provides an independent result for the same expression.
do
  local label = 'reference-matching-backtrack'
  local reference_lanes_ = {}
  for i = 1, 4 do
    reference_lanes_[#reference_lanes_ + 1] = RefOp.put(label, i)
  end
  for i = 1, 4 do
    local lane = RefOp.get(label)
    if i == 1 then
      lane = lane:and_then(RefOp.guard(function(value)
        if value == 4 then
          return RefOp.never()
        end
        return RefOp.always(value)
      end))
    end
    reference_lanes_[#reference_lanes_ + 1] = lane
  end
  local reference = RefOp.together(unpack_(reference_lanes_))
    :map(function()
      return 'preferred'
    end)
    :or_else(RefOp.always('fallback'))

  local channel = Rendezvous.new(label)
  local production_lanes_ = {}
  for i = 1, 4 do
    production_lanes_[#production_lanes_ + 1] = channel:put_op(i)
  end
  for i = 1, 4 do
    local lane = channel:get_op()
    if i == 1 then
      lane = lane:and_then(Op.guard(function(value)
        if value == 4 then
          return Op.never()
        end
        return Op.always(value)
      end))
    end
    production_lanes_[#production_lanes_ + 1] = lane
  end
  local production = Op.together(production_lanes_)
    :map(function()
      return 'preferred'
    end)
    :or_else(Op.always('fallback'))

  eq(reference_result(reference, label), 'preferred')
  eq(production_result(production, label), 'preferred')
end

print('tests/reference/test_frontier_conformance.lua: ok')
