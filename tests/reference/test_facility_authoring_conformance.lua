package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?/init.lua', package.path,
}, ';')

local Conformance = require('tests.support.facility_conformance')
local Facility = require('fibers.resource.authoring')
local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Effect = require('fibers.effect')
local Ref = require('reference.evaluator')
local RefOp = Ref.Op

local Counter = {}
Counter.__index = Counter

local function counter(initial)
  local self = setmetatable({}, Counter)
  self._location = Facility.location(self, { algebra = 'add', value = initial })
  self._give = Facility.rule.change({
    location = self._location,
    resource = self,
    visibility = 'together',
    supply = 'up',
    step = function(_value, amount)
      return Facility.outcome(Facility.patch.add(amount), true)
    end,
  })
  self._take = Facility.rule.change({
    location = self._location,
    resource = self,
    visibility = 'together',
    demand = 'up',
    supply = 'down',
    step = function(value, amount)
      if value < amount then return nil end
      return Facility.outcome(Facility.patch.add(-amount), true)
    end,
  })
  self._at_least = Facility.rule.inspect({
    location = self._location,
    resource = self,
    visibility = 'together',
    demand = 'up',
    step = function(value, threshold)
      if value < threshold then return nil end
      return Facility.outcome(nil, value)
    end,
  })
  return self
end

function Counter:give_op(amount) return Facility.bind(self._give, amount) end
function Counter:take_op(amount) return Facility.bind(self._take, amount) end
function Counter:at_least_op(amount) return Facility.bind(self._at_least, amount) end
function Counter:value() return self._location.value end

local function replace_box(initial)
  local box = {}
  box.location = Facility.location(box, { algebra = 'replace', value = initial })
  box.write = Facility.replace(box.location, Facility.result.boolean, box)
  function box:write_op(value) return Facility.bind(self.write, value) end
  return box
end

local function cursor_machine(count)
  local machine = {}
  machine.location = Facility.location(machine, { algebra = 'machine', value = 0 })
  machine.choose = Facility.rule.change({
    location = machine.location,
    resource = machine,
    visibility = 'together',
    supply = 'any',
    cursor = function(_state)
      local next_value = 0
      return {
        next = function()
          next_value = next_value + 1
          if next_value > count then return nil end
          return Facility.outcome(Facility.patch.machine(next_value), next_value)
        end,
      }
    end,
  })
  function machine:choose_op() return Facility.op(self.choose) end
  return machine
end

local function found_value(op, opts)
  local values = Conformance.expect_found(op, opts)
  return values[1]
end

local law_report = Conformance.check({
  name = 'trusted authoring primitives',

  losing_choices_leave_committed_state_unchanged = function(T)
    local c = counter(0)
    local result = found_value(
      c:give_op(1):and_then(Op.never()):or_else(Op.always('fallback'))
    )
    T.eq(result, 'fallback')
    T.eq(c:value(), 0, 'losing speculative change leaked into committed state')
  end,

  sequential_continuations_see_tentative_changes = function(T)
    local c = counter(0)
    local result = found_value(
      c:give_op(1):and_then(c:at_least_op(1)):map(function(v) return v end)
    )
    T.eq(result, 1, 'sequential continuation did not observe tentative prefix change')
    T.eq(c:value(), 1)
  end,

  each_hides_positive_sibling_supply = function(T)
    local c = counter(0)
    local result = found_value(
      Op.each({ c:give_op(1), c:take_op(1) })
        :map(function() return 'preferred' end)
        :or_else(Op.always('fallback'))
    )
    T.eq(result, 'fallback')
    T.eq(c:value(), 0)
  end,

  together_permits_only_intended_handoff = function(T)
    local c = counter(0)
    local result = found_value(
      Op.together({ c:give_op(1), c:take_op(1) })
        :map(function() return 'preferred' end)
        :or_else(Op.always('fallback'))
    )
    T.eq(result, 'preferred')
    T.eq(c:value(), 0, 'compatible hand-off should have zero net additive change')
  end,

  incompatible_parallel_changes_reject_candidate = function(T)
    local box = replace_box(0)
    local result = found_value(
      Op.each({ box:write_op(1), box:write_op(2) })
        :map(function() return 'bad' end)
        :or_else(Op.always('fallback'))
    )
    T.eq(result, 'fallback')
    T.eq(box.location.value, 0, 'incompatible sibling writes must not partially commit')
  end,

  cursor_alternatives_backtrack_globally = function(T)
    local machine = cursor_machine(2)
    local op = machine:choose_op():and_then(Op.guard(function(value)
      if value == 1 then return Op.never() end
      return Op.always(value)
    end))
    T.eq(found_value(op), 2, 'search should backtrack from rejected first cursor alternative')
    T.eq(machine.location.value, 2)
  end,

  local_exhaustion_is_not_premature_retry = function(T)
    local machine = cursor_machine(3)
    local op = machine:choose_op():and_then(Op.guard(function(value)
      if value < 3 then return Op.never() end
      return Op.always('last-alternative')
    end)):or_else(Op.always('fallback'))
    T.eq(found_value(op), 'last-alternative', 'local cursor exhaustion must not open fallback early')
    T.eq(machine.location.value, 3)
  end,

  unknown_never_opens_fallback = function(T)
    local machine = cursor_machine(64)
    local result
    local rt = Runtime.new()
    rt:spawn_raw(function()
      result = rt:perform(machine:choose_op():and_then(Op.guard(function()
        return Op.never()
      end)):or_else(Op.always('fallback')))
    end):label('facility-unknown-no-fallback')
    T.eq(rt:step({ max_work = 1 }).kind, 'started')
    local budget = rt:step({ max_work = 1 })
    T.eq(budget.tag, 'pending')
    T.eq(budget.kind, 'budget')
    T.eq(result, nil, 'Unknown search must not authorise fallback')
    rt:run()
    T.eq(result, 'fallback', 'fallback becomes valid after exhaustive refutation')
  end,

  stale_candidates_fail_validation = function(T)
    local c = counter(2)
    local first_result, second_result
    local rt = Runtime.new()
    local first = rt:spawn_raw(function()
      first_result = rt:perform(c:take_op(1))
    end):label('facility-stale-first')
    local second = rt:spawn_raw(function()
      second_result = rt:perform(c:take_op(1))
    end):label('facility-stale-second')
    rt:_resume_fiber(first)
    rt:_resume_fiber(second)
    local first_request, second_request = rt.engine.pending[1], rt.engine.pending[2]
    local first_plan = assert(rt.engine:find_candidate(first_request))
    local second_plan = assert(rt.engine:find_candidate(second_request))
    T.truthy(first_plan:settle(rt.engine))
    T.eq(second_plan:settle(rt.engine), false, 'candidate built against stale version must fail validation')
    local refreshed = assert(rt.engine:find_candidate(second_request))
    T.truthy(refreshed:settle(rt.engine))
    T.eq(first_result, true)
    T.eq(second_result, true)
    T.eq(c:value(), 0)
  end,

  post_commit_actions_run_only_for_selected_world = function(T)
    local log = {}
    local Mark
    Mark = Effect.kind({
      name = 'facility-conformance-mark',
      key = function(payload) return payload.name end,
      merge = function(first, _second) return first end,
      prepare = function(_runtime, payload)
        return {
          payload = payload,
          discharge = function(_runtime, prepared)
            log[#log + 1] = prepared.payload.name
          end,
        }
      end,
    })
    local losing = Op.emit(Effect.of(Mark, { name = 'loser' })):and_then(Op.never())
    local selected = Op.emit(Effect.of(Mark, { name = 'selected' })):and_then(Op.always('ok'))
    T.eq(found_value(losing:or_else(selected)), 'ok')
    T.eq(#log, 1)
    T.eq(log[1], 'selected')
  end,
})

Conformance.eq(#law_report.passed, #Conformance.required_laws, 'all required facility laws should execute')

-- Generated finite differential cases. These exercise the authoring compiler and
-- production search against a deliberately separate copy-on-branch evaluator.
local cases = {}
for initial = 0, 3 do
  for give = 1, 2 do
    for take = 1, 2 do
      for extra = 0, 2 do
        for _, mode in ipairs({ 'sequence', 'each', 'together', 'nested' }) do
          cases[#cases + 1] = {
            initial = initial, give = give, take = take, extra = extra, mode = mode,
          }
        end
      end
    end
  end
end

local function ref_expression(case)
  local give = RefOp.add('stock', case.give)
  local take = RefOp.take('stock', case.take)
  local preferred
  if case.mode == 'sequence' then
    preferred = give:and_then(take)
  elseif case.mode == 'each' then
    preferred = RefOp.each(give, take)
  elseif case.mode == 'together' then
    preferred = RefOp.together(give, take)
  else
    preferred = RefOp.together(
      RefOp.each(give, take),
      RefOp.add('stock', case.extra)
    )
  end
  return preferred:map(function() return 'preferred' end):or_else(RefOp.always('fallback'))
end

local function production_expression(case, c)
  local give = c:give_op(case.give)
  local take = c:take_op(case.take)
  local preferred
  if case.mode == 'sequence' then
    preferred = give:and_then(take)
  elseif case.mode == 'each' then
    preferred = Op.each(give, take)
  elseif case.mode == 'together' then
    preferred = Op.together(give, take)
  else
    preferred = Op.together({
      Op.each({ give, take }),
      c:give_op(case.extra),
    })
  end
  return preferred:map(function() return 'preferred' end):or_else(Op.always('fallback'))
end

local generated = Conformance.differential({
  name = 'trusted authoring additive finite model',
  cases = cases,
  reference = function(case)
    return Ref.evaluate(ref_expression(case), {
      locations = { stock = Ref.add_location(case.initial) },
      max_steps = 200000,
    })
  end,
  production = function(case)
    local c = counter(case.initial)
    local value = found_value(production_expression(case, c), {
      quiet_deadlock = true,
      search_total_limit = 20000,
    })
    return { result = value, stock = c:value() }
  end,
  compare = function(case, reference, production)
    Conformance.eq(reference.tag, 'Hit', 'finite reference should decide generated case')
    local allowed = {}
    for i = 1, #reference.worlds do
      local world = reference.worlds[i]
      allowed[tostring(world.result[1]) .. '|' .. tostring(world.locations.stock)] = true
    end
    local key = tostring(production.result) .. '|' .. tostring(production.stock)
    Conformance.truthy(allowed[key],
      'production world not admitted by reference for mode=' .. tostring(case.mode)
        .. ' initial=' .. tostring(case.initial)
        .. ' give=' .. tostring(case.give)
        .. ' take=' .. tostring(case.take)
        .. ' extra=' .. tostring(case.extra)
        .. ': got ' .. key)
  end,
})

Conformance.eq(generated, 192, 'generated differential case count')
print('tests/reference/test_facility_authoring_conformance.lua: ok')
