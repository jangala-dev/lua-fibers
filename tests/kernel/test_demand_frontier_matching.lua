package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
  end
end

local function found(status, message)
  eq(status and status.tag, 'found', message or 'runtime should find a committed world')
end

local function exchange_lanes(channel, puts, gets)
  local lanes = {}
  for _ = 1, puts do lanes[#lanes + 1] = channel:put_op(true) end
  for _ = 1, gets do lanes[#lanes + 1] = channel:get_op() end
  return lanes
end

-- Pending suppliers are tried in response to the active demand, rather than as
-- arbitrary include/exclude subsets. Every supplier can exchange, but its
-- continuation refutes the resulting world.
do
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 64 })
  local channel = Rendezvous.new():label('demand-frontier-failing-suppliers')
  for i = 1, 24 do
    runtime:spawn_raw(function()
      runtime:perform(channel:get_op():and_then(Op.never()))
    end):label('failing-supplier-' .. i)
  end

  local result
  runtime:spawn_raw(function()
    result = runtime:perform(channel:put_op(true):or_else(Op.always('fallback')))
  end):label('supplier-focus')

  found(runtime:run(), 'failing suppliers should be exhaustively refuted within the declared bound')
  eq(result, 'fallback')
end

-- Demand-directed recruitment remains complete for a connected chain of
-- suppliers, including chains which must themselves recruit before supplying
do
  local function chain(length, fail)
    local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 64 })
    local channels = {}
    for i = 1, length do channels[i] = Rendezvous.new():label('demand-chain-' .. i) end

    for i = 1, length do
      local index = i
      runtime:spawn_raw(function()
        local supplier = channels[index]:get_op()
        if index < length then
          supplier = supplier:and_then(channels[index + 1]:put_op(index))
        elseif fail then
          supplier = supplier:and_then(Op.never())
        end
        runtime:perform(supplier)
      end):label('chain-supplier-' .. i)
    end

    local result
    runtime:spawn_raw(function()
      local preferred = channels[1]:put_op(0):map(function() return 'preferred' end)
      result = runtime:perform(preferred:or_else(Op.always('fallback')))
    end):label('chain-focus')
    local status = runtime:run()
    return result, status
  end

  local result, status = chain(16, false)
  found(status, 'a connected supplier chain should commit')
  eq(result, 'preferred')

  result, status = chain(16, true)
  found(status, 'a failing supplier chain should be exhaustively refuted')
  eq(result, 'fallback')
end

-- A large closed frontier with unequal role counts is an exact refutation; it
-- should not consume the ordinary pairing search budget.
do
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 16 })
  local channel = Rendezvous.new():label('closed-frontier-imbalance')
  local result
  runtime:spawn_raw(function()
    local preferred = Op.together(exchange_lanes(channel, 16, 17))
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('imbalanced-focus')
  found(runtime:run())
  eq(result, 'fallback')
end

-- Equal counts and non-empty local domains do not imply a complete world. Two
-- independent roots form a Hall-deficient graph with no perfect matching.
do
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 16 })
  local channel = Rendezvous.new():label('closed-frontier-hall-deficient')
  runtime:spawn_raw(function()
    runtime:perform(Op.each(exchange_lanes(channel, 7, 8)))
  end):label('hall-root-b')

  local result
  runtime:spawn_raw(function()
    local preferred = Op.each(exchange_lanes(channel, 9, 8))
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('hall-root-a')

  found(runtime:run(), 'a closed Hall-deficient frontier should prove absence')
  eq(result, 'fallback')
end

-- The same closed-frontier representation must retain successful matching.
do
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 16 })
  local channel = Rendezvous.new():label('closed-frontier-perfect')
  runtime:spawn_raw(function()
    runtime:perform(Op.each(exchange_lanes(channel, 8, 8)))
  end):label('perfect-root-b')

  local result
  runtime:spawn_raw(function()
    local preferred = Op.each(exchange_lanes(channel, 8, 8)):map(function() return 'preferred' end)
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('perfect-root-a')

  found(runtime:run(), 'a closed frontier with a perfect matching should commit')
  eq(result, 'preferred')
end

-- Complete and constrained resources may share one closed frontier. The
-- complete resource stays implicit while the constrained resource materialises
-- adjacency, and both must contribute to the same committed world.
do
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 32 })
  local complete = Rendezvous.new():label('closed-frontier-mixed-complete')
  local constrained = Rendezvous.new():label('closed-frontier-mixed-constrained')
  runtime:spawn_raw(function()
    runtime:perform(Op.each(exchange_lanes(constrained, 4, 4)))
  end):label('mixed-root-b')

  local result
  runtime:spawn_raw(function()
    local lanes = { Op.together(exchange_lanes(complete, 8, 8)) }
    local constrained_lanes = exchange_lanes(constrained, 4, 4)
    for i = 1, #constrained_lanes do lanes[#lanes + 1] = constrained_lanes[i] end
    local preferred = Op.each(lanes):map(function() return 'preferred' end)
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('mixed-root-a')

  found(runtime:run(), 'mixed complete and constrained resources should commit together')
  eq(result, 'preferred')
end

-- A complete matching is only a preferred branch. If its continuations fail,
-- ordinary exhaustive pairing remains available and may find another world.
do
  local runtime = Runtime.new({ quiet_deadlock = true, search_total_limit = 32 })
  local channel = Rendezvous.new():label('closed-frontier-matching-backtrack')
  local lanes = {}
  for i = 1, 16 do lanes[#lanes + 1] = channel:put_op(i) end
  for i = 1, 16 do
    if i == 1 then
      lanes[#lanes + 1] = channel:get_op():and_then(Op.guard(function(value)
        if value == 16 then return Op.never() end
        return Op.always(value)
      end))
    else
      lanes[#lanes + 1] = channel:get_op()
    end
  end

  local result
  runtime:spawn_raw(function()
    local preferred = Op.together(lanes):map(function() return 'preferred' end)
    result = runtime:perform(preferred:or_else(Op.always('fallback')))
  end):label('matching-backtrack-focus')

  found(runtime:run(), 'failure of the suggested matching must not remove other worlds')
  eq(result, 'preferred')
end

print('tests/kernel/test_demand_frontier_matching.lua: ok')
