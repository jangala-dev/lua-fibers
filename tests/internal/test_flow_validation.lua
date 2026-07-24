package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Flow = require('fibers.flow')

local function eq(a, b, msg)
  if a ~= b then
    error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end

local rt = Runtime.new()
local flow = Flow.new({ name = 'flow-negative-refresh', capacity = 8 })
local got, written
local reader = rt:spawn_raw(function()
  got = rt:perform(flow:outlet():read_exactly_op(1):or_else(Op.always('empty')))
end, 'reader')
rt:_resume_fiber(reader)
local reader_id = rt.pending[#rt.pending].id
local fallback = assert(rt:_find_candidate(reader_id))
eq(fallback.absence_gate ~= nil, true, 'read should initially plan fallback')

local writer = rt:spawn_raw(function()
  written = rt:perform(flow:inlet():write_op('x'))
end, 'writer')
rt:_resume_fiber(writer)
local writer_id = rt.pending[#rt.pending].id
local write_plan = assert(rt:_find_candidate(writer_id))
assert(rt:_commit_hit(write_plan))
eq(written, 1)

eq(rt:_commit_hit(fallback), false, 'flow mutation must invalidate prior fallback proof')
local refreshed = assert(rt:_find_candidate(reader_id))
eq(refreshed.absence_gate ~= nil, false, 'refreshed reader should select primary')
assert(rt:_commit_hit(refreshed))
eq(got, 'x')

print('tests/test_flow_validation.lua: ok')
