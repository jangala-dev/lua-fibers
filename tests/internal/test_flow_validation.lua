package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Flow = require('fibers.resource.flow')

local function eq(a, b, msg)
  if a ~= b then
    error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

local named_a = Flow.new(1):label('shared-debug-name')
local named_b = Flow.new(1):label('shared-debug-name')
eq(named_a:label(), named_b:label(), 'debug labels may be shared')
eq(named_a._fibers_id == named_b._fibers_id, false, 'Flow identity must not depend on its debug name')

local rt = Runtime.new()
local flow = Flow.new(8):label('flow-negative-refresh')
local got, written
local reader = rt:spawn_raw(function()
  got = rt:perform(flow:outlet():read_exactly_op(1):or_else(Op.always('empty')))
end):label('reader')
rt:_resume_fiber(reader)
local reader_request = rt.engine.pending[#rt.engine.pending]
local fallback = assert(rt.engine:find_candidate(reader_request))
eq(fallback:is_fallback(), true, 'read should initially plan fallback')

local writer = rt:spawn_raw(function()
  written = rt:perform(flow:inlet():write_op('x'))
end):label('writer')
rt:_resume_fiber(writer)
local writer_request = rt.engine.pending[#rt.engine.pending]
local write_plan = assert(rt.engine:find_candidate(writer_request))
assert(write_plan:settle(rt.engine))
eq(written, 1)

eq(fallback:settle(rt.engine), false, 'flow mutation must invalidate prior fallback proof')
local refreshed = assert(rt.engine:find_candidate(reader_request))
eq(refreshed:is_fallback(), false, 'refreshed reader should select primary')
assert(refreshed:settle(rt.engine))
eq(got, 'x')

print('tests/test_flow_validation.lua: ok')
