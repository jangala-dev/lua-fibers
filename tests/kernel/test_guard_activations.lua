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

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Cell = require('fibers.resource.cell')
local Rendezvous = require('fibers.resource.rendezvous')
local Sleep = require('fibers.sleep')
local Clock = require('fibers.resource.clock')
local Scope = require('fibers.scope')

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if actual ~= expected then
    fail((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
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

for _, machine in ipairs({ 'ledger', 'reference' }) do
  -- Host-language sharing of an shared guard value must not merge two
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
  -- constructs a different option and succeeds.
  do
    local calls = 0
    local guarded = Op.guard(function()
      calls = calls + 1
      if calls == 1 then
        return Op.never()
      end
      return Op.always('second activation')
    end)
    local result = run(machine, Op.choice(guarded, guarded))
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

  -- The guard argument is an ephemeral perform-local activation view. Its
  -- monotonic instant is sampled at most once, and the public surface exposes
  -- only the stable values needed to construct an explicit residual.
  do
    local reads = 0
    local host = {
      now = function()
        reads = reads + 1
        return 40 + reads
      end,
    }
    local rt = Runtime.new({ machine = machine, host = host })
    local scope = Scope.new('guard-activation-context', { runtime = rt })
    local captured, result
    rt:spawn_raw(function()
      result = pack(rt:perform(Op.guard(function(activation)
        captured = activation
        local first = activation:now()
        local second = activation:now()
        return Op.always(
          first,
          second,
          activation:scope() == scope,
          activation.runtime == nil,
          activation.host == nil,
          type(activation.scope) == 'function',
          activation.label == nil,
          activation._close == nil,
          activation.close == nil
        )
      end)))
    end, 'guard-activation-context-root', scope)
    found(rt:run(), machine .. ': guard activation context should complete')
    eq(result[1], result[2], machine .. ': one activation should observe one instant')
    eq(reads, 1, machine .. ': activation time should be sampled once')
    eq(result[3], true, machine .. ': activation should expose the performing Scope')
    eq(result[4], true, machine .. ': activation should not expose the Runtime')
    eq(result[5], true, machine .. ': activation should not expose the Runtime host')
    eq(result[6], true, machine .. ': activation should expose only the Scope method')
    eq(result[7], true, machine .. ': activation should not expose its internal label')
    eq(result[8], true, machine .. ': activation should not expose evaluator closure')
    eq(result[9], true, machine .. ': activation should expose no module closure function')
    local open, err = pcall(function()
      return captured:now()
    end)
    eq(open, false, machine .. ': activation view must not outlive guard elaboration')
    eq(
      tostring(err):match('no longer available') ~= nil,
      true,
      machine .. ': closed activation should explain its lifetime'
    )
  end

  -- Contextual surface operations resolve against the performing activation,
  -- not the host-language point where the reusable guard value was constructed.
  do
    local contextual = Op.guard(function(activation)
      return Op.always(activation:scope())
    end)
    local rt = Runtime.new({ machine = machine })
    local outer = Scope.new('guard-context-outer', { runtime = rt })
    local inner = Scope.new('guard-context-inner', { runtime = rt, parent = outer })
    local observed_scope
    rt:spawn_raw(function()
      rt:with_scope(inner, function()
        observed_scope = rt:perform(contextual)
      end)
    end, 'guard-context-performing-scope', outer)
    found(rt:run(), machine .. ': contextual guard should complete')
    eq(observed_scope, inner, machine .. ': guard should resolve the performing Scope')
  end

  -- A changed transactional observation creates a new activation even when
  -- the earlier progression remains pending behind a guarded option.
  do
    local rt = Runtime.new({ machine = machine })
    local cell = Cell.new(0, 'guard-activation-version')
    local gate = Rendezvous.new('guard-activation-gate')
    local calls, value, activation_number = 0, nil, nil

    rt:spawn_raw(function()
      value, activation_number = rt:perform(cell:read_op():and_then(function(observed)
        return Op.guard(function()
          calls = calls + 1
          return gate:get_op():map(function()
            return observed, calls
          end)
        end)
      end))
    end, 'guard-version-waiter')

    rt:spawn_raw(function()
      rt:perform(cell:write_op(1))
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
    local cell = Cell.new(0, 'guard-fallback-version')
    local gate = Rendezvous.new('guard-fallback-gate')
    local calls, result = 0, nil
    local preferred = cell:changed_op(0):and_then(function()
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
      rt:perform(cell:write_op(1))
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
