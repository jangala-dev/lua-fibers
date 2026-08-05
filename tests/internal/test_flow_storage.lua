package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Errors = require('fibers.resource.flow.errors')
local Inspect = require('tests.support.flow_inspect')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function assert_status(st, tag, msg)
  if not st or st.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag))
  end
end

-- Lease methods remain callable and expose the leased bytes directly.
do
  local flow = require('fibers.resource.flow').new(10):label('lease-method-flow')
  local lease, len
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcdef'))
    lease = fibers.perform(flow:outlet():lease_some_op(3, 'holder-a'))
    len = lease:length()
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(lease, 'lease should commit')
  assert_eq(len, 3, 'lease:length should return leased byte length')
  assert_eq(lease:bytes(), 'abc', 'lease:bytes should return leased bytes')
end

-- The current Flow storage algebra intentionally permits only one active lease per
-- Flow.  A second holder cannot acquire a lease until the first is acked,
-- returned, failed, or settled.
do
  local flow = require('fibers.resource.flow').new(10):label('single-active-lease-flow')
  local first, second, second_err, after_ack
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcdef'))
    first = fibers.perform(flow:outlet():lease_some_op(3, 'holder-a'))
    second, second_err = fibers.perform(flow:outlet():lease_some_op(3, 'holder-b'))
    fibers.perform(first:ack_op(3))
    after_ack = fibers.perform(flow:outlet():lease_some_op(3, 'holder-b'))
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(first, 'first lease should commit')
  assert_eq(first:bytes(), 'abc')
  assert_eq(second, nil, 'second active lease should be rejected')
  assert_eq(second_err, Errors.LEASE_ALREADY_ACTIVE, 'second lease rejection should be explicit')
  assert_truthy(after_ack, 'new lease should be possible after ack')
  assert_eq(after_ack:bytes(), 'def')
end

-- Queued bytes are stored as a rope of chunks rather than a single mutable
-- concatenated string.  The public observation remains a byte stream.
do
  local flow = require('fibers.resource.flow').new(64):label('rope-backed-flow')
  local chunks, data, got
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('ab'))
    fibers.perform(flow:inlet():write_op('cd'))
    fibers.perform(flow:inlet():write_op('ef'))
    chunks = Inspect.chunk_count(flow)
    data = Inspect.data(flow)
    got = fibers.perform(flow:outlet():read_exactly_op(6))
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(chunks >= 3, 'rope-backed Flow should retain append chunks')
  assert_eq(data, 'abcdef', 'test representation should retain the byte stream')
  assert_eq(got, 'abcdef', 'reads should preserve stream order')
end

print('tests/test_flow_storage.lua: ok')
