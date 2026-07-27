package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local Clock = require('fibers.resource.clock')
local Host = require('fibers.host')
local SimulatedHost = require('tests.support.simulated_host')
local socket = require('fibers.socket')
local Address = require('fibers.socket.address')
local Completion = require('fibers.resource.completion')
local DialLifecycle = require('fibers.socket.dial_lifecycle')
local Race = require('fibers.internal.socket.happy_eyeballs_race')
local clock = Clock.default()

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(
      (message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual),
      2
    )
  end
end

local function assert_truthy(value, message)
  if not value then
    error(message or 'expected truthy value', 2)
  end
end

-- Clock observations used by provisional continuations are managed facts. Two
-- observations in one product share the same proof-time instant.
do
  local host = SimulatedHost.new()
  local result = fibers.try_run(function()
    local observed = fibers.perform(Op.named_all({
      left = clock:now_op(),
      right = clock:now_op(),
    }))
    assert_eq(observed.left, 0)
    assert_eq(observed.right, observed.left)

    Sleep.sleep(0.125)
    local later = fibers.perform(clock:now_op())
    assert_eq(later, 0.125)
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
end

-- A Dial report is installed with the lifecycle transition and survives claim;
-- there is no second completion which can disagree with the lifecycle.
do
  local result = fibers.try_run(function()
    local lifecycle = DialLifecycle.new('reference-report', Address.name('example.test', 443))
    local connection, source_scope = {}, {}
    local report = { status = 'connected', attempt = 1 }
    local published = fibers.perform(lifecycle:publish_connected_op(connection, source_scope, report))
    assert_eq(published, true)
    local taken, source, taken_report = fibers.perform(lifecycle:take_op())
    assert_eq(taken, connection)
    assert_eq(source, source_scope)
    assert_eq(taken_report, report)
    assert_eq(fibers.perform(lifecycle:report_op()), report)
  end)
  assert_truthy(result.ok, result:tostring())
end

-- Query result state is a projection of the two authoritative family
-- completions. A custom family backend never publishes a third combined fact.
do
  local host = SimulatedHost.new({ sockets = true, resolver = false })
  local result = fibers.try_run(function()
    local resolver = {
      resolve = function()
        error('combined resolver path must not be used')
      end,
      resolve_family = function(_self, endpoint, family)
        if family == 'inet6' then
          return {}
        end
        return { socket.ipv4_address('192.0.2.10', endpoint.service) }
      end,
    }
    local query = socket.resolve_name('derived.test', 443, { resolver = resolver })
    local families = fibers.perform(Op.named_all({
      inet6 = query:family_finished_op('inet6'),
      inet4 = query:family_finished_op('inet4'),
    }))
    local addresses, err = query:result()
    assert_truthy(addresses, tostring(err))
    assert_eq(#addresses, 1)
    assert_eq(addresses[1].kind, 'inet4')
    assert_eq(families.inet6.kind, 'succeeded')
    assert_eq(families.inet4.kind, 'succeeded')
    local state = query.state_op and fibers.perform(query:state_op()) or nil
    assert_truthy(state and state.kind == 'succeeded')
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
end

-- Family validation, ordering, diversity reservation and capacity accounting
-- are established by the committing PublishFamily transition itself.
do
  local host = SimulatedHost.new()
  local result = fibers.try_run(function()
    local endpoint = Address.name('example.test', 443)
    local race = Race.new(endpoint, {
      name = 'reference-candidates',
      host = host,
      resolution_delay = 0.050,
      attempt_delay = 0.250,
      first_family_count = 1,
      maximum_candidates = 2,
      maximum_active_attempts = 2,
      overall_deadline = 10,
    }, host, 0)

    local v6 = Completion.new('reference-v6')
    fibers.perform(v6:publish_success_op({
      Address.ipv6('2001:db8::1', 443),
      Address.ipv6('2001:db8::2', 443),
    }))
    fibers.perform(race:publish_family_op('inet6', v6:state_value(), 0))
    local first = race.state.value
    assert_eq(#first.unattempted, 1, 'one slot remains reserved for the unfinished family')
    assert_eq(first.candidates_dropped, 1)

    local v4 = Completion.new('reference-v4')
    fibers.perform(v4:publish_success_op({ Address.ipv4('192.0.2.20', 443) }))
    fibers.perform(race:publish_family_op('inet4', v4:state_value(), 0.010))
    local second = race.state.value
    assert_eq(#second.unattempted, 2)
    assert_eq(second.unattempted[1].kind, 'inet6')
    assert_eq(second.unattempted[2].kind, 'inet4')
    assert_eq(race.attempt_slots.value, 2)
  end, { host = host })
  assert_truthy(result.ok, result:tostring())
end

print('tests/internal/test_algebraic_dns_reference.lua: ok')
