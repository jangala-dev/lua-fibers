-- Speculative-activation-scoped CML-style guard semantics.

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

local Op = require('fibers.atoms.op')
local Runtime = require('fibers.kernel.runtime')
local Scalar = require('fibers.atoms.scalar')
local Rendezvous = require('fibers.atoms.rendezvous')
local Sleep = require('fibers.sleep')

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if actual ~= expected then
    fail(
      (message or 'values differ')
        .. ': expected '
        .. tostring(expected)
        .. ', got '
        .. tostring(actual)
    )
  end
end

local function found(status, message)
  if not status or status.tag ~= 'found' then
    fail((message or 'expected found') .. ': got ' .. tostring(status and status.tag))
  end
end

local function pack(...)
  return { n = select('#', ...), ... }
end

local function run(machine, op, opts)
  opts = opts or {}
  opts.machine = machine
  local rt = Runtime.new(opts)
  local result
  rt:spawn_raw(function()
    result = pack(rt:perform(op))
  end, 'guard-activation-root')
  local status = rt:run()
  found(status)
  return result, rt
end

for _, machine in ipairs({ 'trail', 'reference' }) do
  -- Host-language sharing of an immutable guard value must not merge two
  -- tensor operands into one dynamic activation.
  do
    local calls = 0
    local guarded = Op.guard(function()
      calls = calls + 1
      return Op.always(calls)
    end)
    local result = run(machine, Op.tensor({ guarded, guarded }))
    local rows = result[1]
    eq(calls, 2, machine .. ': tensor should force two guard activations')
    eq(rows[1][1] == rows[2][1], false, machine .. ': tensor activations should be independent')
  end

  -- The same rule applies when sharing is hidden behind a reused and_then
  -- description.  Each structural use receives its own continuation and guard
  -- activations.
  do
    local calls = 0
    local guarded = Op.guard(function()
      calls = calls + 1
      return Op.always(calls)
    end)
    local sequence = Op.always('prefix'):and_then(function()
      return guarded
    end)
    local result = run(machine, Op.tensor({ sequence, sequence }))
    local rows = result[1]
    eq(calls, 2, machine .. ': reused dynamic sequence should create two guard activations')
    eq(rows[1][1] == rows[2][1], false, machine .. ': dynamic activations should be independent')
  end

  -- Separate choice positions are separate activations even when they point at
  -- the same guard value.  The first demanded activation retries; the second
  -- constructs a different operation and succeeds.
  do
    local calls = 0
    local guarded = Op.guard(function()
      calls = calls + 1
      if calls == 1 then
        return Op.never()
      end
      return Op.always('second activation')
    end)
    local result = run(machine, Op.choice(guarded, guarded), {
      state_memoization = true,
      state_memoization_min_steps = 0,
      state_memoization_min_intents = 0,
    })
    eq(result[1], 'second activation', machine .. ': second guard activation should be searched')
    eq(calls, 2, machine .. ': choice positions must not share a guard expansion')
  end

  -- Distinct provisional proofs entering one and_then continuation are
  -- distinct speculative activations, even when they return equal Lua values.
  do
    local calls = 0
    local left = Op.choice(Op.always('same'), Op.always('same'))
    local op = left:and_then(function(value)
      return Op.guard(function()
        calls = calls + 1
        if calls == 1 then
          return Op.never()
        end
        return Op.always(value, calls)
      end)
    end)
    local result = run(machine, op)
    eq(result[1], 'same')
    eq(result[2], 2)
    eq(calls, 2, machine .. ': distinct left proofs should activate guards independently')
  end

  -- A relative sleep returned by and_then begins when that provisional
  -- progression activates, not when the outer perform begins.  Repeated
  -- driver steps retain the resulting deadline.
  do
    local now = 0
    local rt = Runtime.new({
      machine = machine,
      host = {
        now = function()
          return now
        end,
      },
    })
    local gate = Rendezvous.new('guard-activation-sleep-gate')
    local finished, observed = false, nil

    rt:spawn_raw(function()
      local _, deadline = rt:perform(gate:get_op():and_then(function()
        return Sleep.sleep_op(3)
      end))
      finished, observed = true, deadline
    end, 'guard-activation-sleeper')

    eq(rt:run().tag, 'quiescent', machine .. ': left progression should initially block')
    now = 10
    rt:spawn_raw(function()
      rt:perform(gate:put_op(true))
    end, 'guard-activation-sleep-release')
    eq(rt:run().tag, 'pending', machine .. ': sleep should begin after left activation')
    eq(finished, false)

    now = 12
    eq(rt:step().tag, 'pending', machine .. ': activation-relative deadline should remain pending')
    eq(finished, false)

    now = 13
    found(rt:step(), machine .. ': activation-relative sleep should finish')
    eq(finished, true)
    eq(observed, 13, machine .. ': sleep deadline should be fixed at activation plus delay')
  end

  -- A changed transactional observation creates a new activation even when
  -- the earlier progression remains pending behind a guarded operation.
  do
    local rt = Runtime.new({ machine = machine })
    local scalar = Scalar.new(0, 'guard-activation-version')
    local gate = Rendezvous.new('guard-activation-gate')
    local calls, value, activation_number = 0, nil, nil

    rt:spawn_raw(function()
      value, activation_number = rt:perform(scalar:read_op():and_then(function(observed)
        return Op.guard(function()
          calls = calls + 1
          return gate:get_op():map(function()
            return observed, calls
          end)
        end)
      end))
    end, 'guard-version-waiter')

    rt:spawn_raw(function()
      rt:perform(scalar:write_op(1))
    end, 'guard-version-writer')

    found(rt:run(), machine .. ': writer should commit')
    eq(calls, 2, machine .. ': a new observed version should create a new activation')
    eq(value, nil, machine .. ': guarded continuation should still be pending')

    rt:spawn_raw(function()
      rt:perform(gate:put_op(true))
    end, 'guard-version-release')

    found(rt:run(), machine .. ': guarded continuation should complete')
    eq(value, 1, machine .. ': continuation should use the refreshed observation')
    eq(activation_number, 2, machine .. ': refreshed guard activation should remain fixed')
    eq(calls, 2, machine .. ': resuming the same activation must not rerun its guard')
  end

  -- Explicit construction sharing remains expressible by placing duplicated
  -- use inside one outer guard.
  do
    local calls = 0
    local op = Op.guard(function()
      calls = calls + 1
      local prepared = Op.always('shared-' .. tostring(calls))
      return Op.tensor({ prepared, prepared })
    end)
    local result = run(machine, op)
    local rows = result[1]
    eq(calls, 1, machine .. ': one outer guard should construct once')
    eq(rows[1][1], 'shared-1')
    eq(rows[2][1], 'shared-1')
  end

  -- A fallback activation is tied to the certified Retry proof which opened
  -- it.  If that proof changes, the fallback guard is prepared afresh.
  do
    local rt = Runtime.new({ machine = machine })
    local scalar = Scalar.new(0, 'guard-fallback-version')
    local gate = Rendezvous.new('guard-fallback-gate')
    local calls, result = 0, nil
    local preferred = scalar:changed_op(0):and_then(function()
      return Op.never()
    end)
    local fallback = Op.guard(function()
      calls = calls + 1
      local activation_number = calls
      return gate:get_op():map(function()
        return activation_number
      end)
    end)

    rt:spawn_raw(function()
      result = rt:perform(preferred:or_else(fallback))
    end, 'guard-fallback-waiter')

    local initial = rt:run()
    eq(
      initial.tag == 'quiescent' or initial.tag == 'pending',
      true,
      machine .. ': fallback should initially remain blocked'
    )
    eq(calls, 1, machine .. ': initial Retry proof should activate one fallback guard')

    rt:spawn_raw(function()
      rt:perform(scalar:write_op(1))
    end, 'guard-fallback-version-writer')
    local refreshed = rt:run()
    eq(
      refreshed.tag == 'quiescent' or refreshed.tag == 'pending' or refreshed.tag == 'found',
      true,
      machine .. ': changed preferred proof should be processed'
    )
    eq(calls, 2, machine .. ': changed Retry proof should create a new fallback activation')

    rt:spawn_raw(function()
      rt:perform(gate:put_op(true))
    end, 'guard-fallback-release')
    found(rt:run(), machine .. ': refreshed fallback should complete')
    eq(result, 2, machine .. ': committed fallback should use the refreshed activation')
    eq(calls, 2, machine .. ': completing the refreshed fallback must not rerun its guard')
  end

  -- Guard forcing is demand-driven.  A residual fallback that is not opened is
  -- not an activated activation.
  do
    local calls = 0
    local fallback = Op.guard(function()
      calls = calls + 1
      return Op.always('fallback')
    end)
    local result = run(machine, Op.always('primary'):or_else(fallback))
    eq(result[1], 'primary')
    eq(calls, 0, machine .. ': unused fallback guard should remain unforced')
  end

  -- Retained bounded search revisits one activation rather than reconstructing
  -- it on every driver step.
  do
    local calls = 0
    local guarded = Op.guard(function()
      calls = calls + 1
      return Op.always('bounded')
    end)
    local rt = Runtime.new({ machine = machine, search_limit = 100 })
    local value
    rt:spawn_raw(function()
      value = rt:perform(guarded)
    end, 'bounded-guard')
    local status
    for _ = 1, 100 do
      status = rt:step({ max_work = 1 })
      if status.tag == 'found' then
        break
      end
    end
    found(status, machine .. ': bounded search should finish')
    eq(value, 'bounded')
    eq(calls, 1, machine .. ': bounded resumption should reuse the guard expansion')
  end
end

print('tests/test_guard_activations.lua: ok')
