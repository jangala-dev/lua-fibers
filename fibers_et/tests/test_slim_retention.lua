-- Regression tests for bounded runtime and ownership bookkeeping.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Runtime = require('fibers.kernel.runtime')
local Region = require('fibers.atoms.region')
local Signal = require('fibers.atoms.signal')

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg)
  if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end
local function collect()
  for _ = 1, 6 do collectgarbage('collect') end
end

-- Repeated batches must consume and reset the ready queue. Completed handles
-- retain identity and status only, not coroutine stacks or scope graphs.
do
  local rt = Runtime.new()
  for batch = 1, 40 do
    local handles = {}
    for i = 1, 25 do
      handles[i] = rt:spawn_raw(function() return batch, i end, 'short')
    end
    local st = rt:run()
    eq(st.tag, 'idle', 'short-fibre batch should drain')
    eq(rt._live_fibers, 0, 'runtime must not retain completed fibres as live')
    eq(rt._ready_head, 1, 'ready queue head should reset')
    eq(rt._ready_tail, 0, 'ready queue tail should reset')
    eq(next(rt._ready_fibers), nil, 'ready queue backing table should be empty')
    for i = 1, #handles do
      eq(handles[i].done, true, 'completed handle should report done')
      eq(handles[i].co, nil, 'completed handle should release its coroutine')
      eq(handles[i].scope, nil, 'completed handle should release its scope')
      eq(handles[i].scope_stack, nil, 'completed handle should release its scope stack')
    end
  end
end

-- The runtime's feed interning cache is a convenience cache, not an ownership
-- registry. Neither the feed nor its resource should be retained by it.
do
  local rt = Runtime.new()
  local weak = setmetatable({}, { __mode = 'v' })
  do
    local resource = Signal.new('temporary-feed-resource')
    local feed = rt:external_feed(resource)
    weak[1], weak[2] = resource, feed
  end
  collect()
  eq(weak[1], nil, 'external-feed cache should not retain a resource')
  eq(weak[2], nil, 'external-feed cache should not retain a feed')
end

-- Retired ownership records must leave the module-global ledger entirely once
-- a region becomes empty; otherwise short-lived scopes accumulate forever.
do
  local weak = setmetatable({}, { __mode = 'v' })
  do
    local rt = Runtime.new()
    local region = Region.new('temporary-region')
    local item = Region.handle('temporary-item')
    weak[1], weak[2] = region, item
    rt:spawn_raw(function()
      rt:perform(region:admit_op(Region.inert(item)))
      rt:perform(region:release_op(item))
    end, 'temporary-owner')
    while true do
      local st = rt:run()
      if st.tag == 'idle' or st.tag == 'quiescent' then break end
    end
    rt, region, item = nil, nil, nil
  end
  collect()
  eq(weak[1], nil, 'empty ownership ledger should not retain a region')
  eq(weak[2], nil, 'retired ownership ledger should not retain an item')
end

print('tests/test_slim_retention.lua: ok')
