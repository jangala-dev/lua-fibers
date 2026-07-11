-- Adversarial cursor-validity tests for production managed facts.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Validity = require('fibers.kernel.validity')
local Resources = require('fibers.kernel.resources')
local Debug = require('fibers.kernel.transaction_debug')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')

local pack_ = Op._pack

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end

local ManagedKind = { name = 'managed-validity-test' }

function ManagedKind.eval(resource, payload, ctx)
  local op = payload.op
  if op == 'map_get' then
    local value, present = resource.map:get(ctx, payload.key)
    if present then return Result.ready(Proposal.new(pack_(value))) end
    return ctx:retry('map-missing')
  elseif op == 'map_expect' then
    local value, present = resource.map:get(ctx, payload.key)
    if present and value == payload.expected then return Result.ready(Proposal.new(pack_(value))) end
    return ctx:retry('map-value-mismatch')
  elseif op == 'lease_free' then
    if resource.leases:is_free(ctx, payload.key) then return Result.ready(Proposal.new(pack_(true))) end
    return ctx:retry('claim-not-free')
  elseif op == 'derived_true' then
    if resource.view:get(ctx) == true then return Result.ready(Proposal.new(pack_(true))) end
    return ctx:retry('derived-false')
  end
  error('unknown managed-validity test op ' .. tostring(op), 2)
end


local function new_managed_resource(name)
  local resource = {
    _fibers_id = name,
    _fibers_kind = ManagedKind,
    map = Validity.map(name .. ':map'),
    leases = Validity.lease(name .. ':leases'),
    gate = Validity.scalar(false, name .. ':gate'),
    members = Validity.set(name .. ':members'),
  }
  resource.view = Validity.derived(function(ctx)
    return resource.gate:get(ctx) and resource.members:contains(ctx, 'ready')
  end, name .. ':derived', { cache = true })
  return resource
end

local function op(resource, payload) return Op._resource(resource, ManagedKind, payload) end
local function map_get_op(resource, key) return op(resource, { op = 'map_get', key = key }) end
local function map_expect_op(resource, key, expected) return op(resource, { op = 'map_expect', key = key, expected = expected }) end
local function lease_free_op(resource, key) return op(resource, { op = 'lease_free', key = key }) end
local function derived_true_op(resource) return op(resource, { op = 'derived_true' }) end

local function drive_until_cache(rt, label)
  for _ = 1, 40 do
    rt:step({ max_work = 1 })
    local observer = Debug.wait_cache_observer(rt)
    if observer then return observer end
  end
  fail('expected wait cache for ' .. tostring(label))
end

local function drive_until_value(rt, get_value, expected, label)
  for _ = 1, 80 do
    rt:step({ max_work = 1 })
    if get_value() == expected then return end
  end
  fail('expected ' .. tostring(label) .. ' to become ' .. tostring(expected) .. ', got ' .. tostring(get_value()))
end

-- A cursor that observed one missing key must survive unrelated key changes, but
-- must be rejected when that specific key appears.
do
  local rt = Runtime.new()
  local r = new_managed_resource('cursor-map-missing')
  local got
  rt:spawn_raw(function() got = rt:perform(map_get_op(r, 'target')) end, 'cursor-map-missing-fibre')
  local obs = drive_until_cache(rt, 'map missing')
  r.map:set('other', 1)
  assert_eq(Resources.observer_valid(obs), true, 'unrelated map key must not invalidate missing-key cursor')
  r.map:set('target', 'payload')
  assert_eq(Resources.observer_valid(obs), false, 'target key appearance must invalidate missing-key cursor')
  drive_until_value(rt, function() return got end, 'payload', 'map target')
end

-- A value-sensitive cursor must not be invalidated by membership-only changes,
-- but must be rejected when the observed key's value changes to the expected one.
do
  local rt = Runtime.new()
  local r = new_managed_resource('cursor-map-value')
  r.map:set('target', 'old')
  local got
  rt:spawn_raw(function() got = rt:perform(map_expect_op(r, 'target', 'new')) end, 'cursor-map-value-fibre')
  local obs = drive_until_cache(rt, 'map value')
  r.map:set('other', 'noise')
  assert_eq(Resources.observer_valid(obs), true, 'unrelated structure change must not invalidate observed key value')
  r.map:set('target', 'old')
  assert_eq(Resources.observer_valid(obs), true, 'same value write must not invalidate observed key value')
  r.map:set('target', 'new')
  assert_eq(Resources.observer_valid(obs), false, 'observed value change must invalidate cursor')
  drive_until_value(rt, function() return got end, 'new', 'map expected value')
end

-- Lease free-ness is a membership fact.  Owner transfer while still leased
-- should not invalidate a waiter for "free"; release should.
do
  local rt = Runtime.new()
  local r = new_managed_resource('cursor-lease')
  assert_eq(r.leases:acquire('slot', 'owner-a'), true)
  local got
  rt:spawn_raw(function() got = rt:perform(lease_free_op(r, 'slot')) end, 'cursor-lease-fibre')
  local obs = drive_until_cache(rt, 'lease free')
  assert_eq(r.leases:transfer('slot', 'owner-a', 'owner-b'), true)
  assert_eq(Resources.observer_valid(obs), true, 'owner transfer must not invalidate free-ness observation')
  assert_eq(r.leases:release('slot', 'owner-b'), true)
  assert_eq(Resources.observer_valid(obs), false, 'release must invalidate free-ness observation')
  drive_until_value(rt, function() return got end, true, 'lease free')
end

-- A cached derived view must carry only the dependencies its body actually read.
-- The first false result short-circuits on gate=false, so member changes are not
-- dependencies until the gate is true and the view recomputes.
do
  local rt = Runtime.new()
  local r = new_managed_resource('cursor-derived')
  local got
  rt:spawn_raw(function() got = rt:perform(derived_true_op(r)) end, 'cursor-derived-fibre')
  local obs = drive_until_cache(rt, 'derived true')
  r.members:add('ready')
  assert_eq(Resources.observer_valid(obs), true, 'unread derived dependency must not invalidate cursor')
  r.gate:set(true)
  assert_eq(Resources.observer_valid(obs), false, 'observed scalar dependency must invalidate cursor')
  drive_until_value(rt, function() return got end, true, 'derived true')
end

print('tests/test_validity_cursor_adversarial.lua: ok')
