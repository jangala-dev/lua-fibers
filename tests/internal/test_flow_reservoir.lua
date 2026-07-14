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

local fibers = require('fibers')
local Errors = require('fibers.internal.flow.errors')

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

-- Lease:length and Lease:inspect should be callable methods, not shadowed by
-- fields on the lease table.
do
  local flow = require('fibers.internal.flow').new({ name = 'lease-method-flow', capacity = 10 })
  local lease, len, info
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcdef'))
    lease = fibers.perform(flow:outlet():lease_some_op(3, 'owner-a'))
    len = lease:length()
    info = lease:inspect()
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(lease, 'lease should commit')
  assert_eq(len, 3, 'lease:length should return leased byte length')
  assert_eq(info.length, 3, 'lease:inspect should report length')
  assert_eq(info.bytes, 'abc', 'lease:inspect should report bytes')
end

-- The current reservoir algebra intentionally permits only one active lease per
-- reservoir.  A second owner cannot acquire a lease until the first is acked,
-- returned, failed, or settled.
do
  local flow = require('fibers.internal.flow').new({ name = 'single-active-lease-flow', capacity = 10 })
  local first, second, second_err, after_ack
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('abcdef'))
    first = fibers.perform(flow:outlet():lease_some_op(3, 'owner-a'))
    second, second_err = fibers.perform(flow:outlet():lease_some_op(3, 'owner-b'))
    fibers.perform(first:ack_op(3))
    after_ack = fibers.perform(flow:outlet():lease_some_op(3, 'owner-b'))
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
  local flow = require('fibers.internal.flow').new({ name = 'rope-backed-flow', capacity = 64 })
  local snap, got
  local st = fibers.try_run(function()
    fibers.perform(flow:inlet():write_op('ab'))
    fibers.perform(flow:inlet():write_op('cd'))
    fibers.perform(flow:inlet():write_op('ef'))
    snap = fibers.perform(flow:inspect_op())
    got = fibers.perform(flow:outlet():read_exactly_op(6))
  end).runtime_status
  assert_status(st, 'found')
  assert_truthy(snap.chunk_count >= 3, 'rope-backed reservoir should retain append chunks')
  assert_eq(snap.data, 'abcdef', 'inspection should materialise the byte stream')
  assert_eq(got, 'abcdef', 'reads should preserve stream order')
end

print('tests/test_flow_reservoir.lua: ok')
