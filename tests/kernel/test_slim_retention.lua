-- Regression tests for bounded runtime and ownership bookkeeping.
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local Runtime = require('fibers.runtime')
local Lifetime = require('fibers.lifetime')
local Scope = require('fibers.scope')
local Signal = require('fibers.resource.signal')

local function fail(msg)
  error(msg, 2)
end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function collect()
  for _ = 1, 6 do
    collectgarbage('collect')
  end
end

-- Repeated batches must consume and reset the ready queue. Completed handles
-- retain identity and status only, not coroutine stacks or scope graphs.
do
  local rt = Runtime.new()
  for batch = 1, 40 do
    local handles = {}
    for i = 1, 25 do
      handles[i] = rt:spawn_raw(function()
        return batch, i
      end):label('short')
    end
    local st = rt:run()
    eq(st.tag, 'idle', 'short-fiber batch should drain')
    eq(rt._live_fibers, 0, 'runtime must not retain completed fibers as live')
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
    local resource = Signal.new():label('temporary-feed-resource')
    local feed = External.external_feed(rt, resource)
    weak[1], weak[2] = resource, feed
  end
  collect()
  eq(weak[1], nil, 'external-feed cache should not retain a resource')
  eq(weak[2], nil, 'external-feed cache should not retain a feed')
end

-- A completed runtime-local Lifetime store retains neither empty Scope
-- capabilities nor retired resources after the Runtime itself is released.
do
  local weak = setmetatable({}, { __mode = 'v' })
  do
    local rt = Runtime.new()
    local scope = Scope.new( { runtime = rt }):label('temporary-scope')
    local item = { name = 'temporary-item' }
    Lifetime.inert(item)
    weak[1], weak[2], weak[3] = scope, item, rt
    rt:_spawn_raw(function()
      scope:run(function(s)
        rt:perform(s:admit_op(item))
      end)
    end,  scope):label('temporary-owner')
    while true do
      local st = rt:run()
      if st.tag == 'idle' or st.tag == 'quiescent' then break end
    end
    local snapshot
    rt:spawn_raw(function() snapshot = rt:perform(scope:inspect_op()) end):label('empty-store-snapshot')
    rt:run()
    eq(snapshot.custody_count, 0, 'completed Scope should retain no Lifetime records under custody')
    rt, scope, item, snapshot = nil, nil, nil, nil
  end
  collect()
  eq(weak[1], nil, 'runtime-local store should not retain an empty Scope')
  eq(weak[2], nil, 'runtime-local store should not retain a retired resource')
  eq(weak[3], nil, 'discarding a Runtime should release its Lifetime store')
end

print('tests/test_slim_retention.lua: ok')
