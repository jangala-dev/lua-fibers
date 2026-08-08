-- Executable conformance support for trusted primitive facilities.
--
-- This module deliberately lives with the repository test support rather than
-- in the runtime package. Primitive authoring through fibers.resource.authoring
-- is a trusted repository boundary; every such facility should account for the
-- complete law list below and may additionally compare finite cases against the
-- independent reference evaluator.

local Runtime = require('fibers.runtime')

local M = {}

M.required_laws = {
  'losing_choices_leave_committed_state_unchanged',
  'sequential_continuations_see_tentative_changes',
  'each_hides_positive_sibling_supply',
  'together_permits_only_intended_handoff',
  'incompatible_parallel_changes_reject_candidate',
  'cursor_alternatives_backtrack_globally',
  'local_exhaustion_is_not_premature_retry',
  'unknown_never_opens_fallback',
  'stale_candidates_fail_validation',
  'post_commit_actions_run_only_for_selected_world',
}

local function fail(message, level)
  error(message, (level or 1) + 1)
end

function M.eq(actual, expected, message)
  if actual ~= expected then
    fail((message or 'values differ') .. ': expected ' .. tostring(expected)
      .. ', got ' .. tostring(actual), 2)
  end
end

function M.truthy(value, message)
  if not value then fail(message or 'expected truthy value', 2) end
  return value
end


-- Correct nil-preserving one-operation runner. Kept separate from the internal
-- engine so facility-law tests normally exercise only public runtime behaviour.
function M.run(op, opts)
  local runtime = Runtime.new(opts or {})
  local values = { n = 0 }
  runtime:spawn_raw(function()
    local function capture(...)
      values = { n = select('#', ...), ... }
    end
    capture(runtime:perform(op))
  end):label('facility-conformance')
  local status = runtime:run()
  return status, values, runtime
end

function M.expect_found(op, opts)
  local status, values, runtime = M.run(op, opts)
  M.eq(status and status.tag, 'found', 'facility law should find a committing world')
  return values, runtime, status
end

-- Require explicit coverage for every trusted-authoring law. A law may be
-- marked false only with an explanatory string in spec.not_applicable[name].
function M.check(spec)
  if type(spec) ~= 'table' then fail('facility conformance expects a spec table', 2) end
  local name = spec.name or 'facility'
  local not_applicable = spec.not_applicable or {}
  local report = { name = name, passed = {}, skipped = {} }
  for i = 1, #M.required_laws do
    local law = M.required_laws[i]
    local check = spec[law]
    if type(check) == 'function' then
      local ok, err = pcall(check, M)
      if not ok then
        fail(name .. ' violates ' .. law .. ': ' .. tostring(err), 2)
      end
      report.passed[#report.passed + 1] = law
    else
      local reason = not_applicable[law]
      if type(reason) ~= 'string' or reason == '' then
        fail(name .. ' conformance is missing required law ' .. law, 2)
      end
      report.skipped[#report.skipped + 1] = { law = law, reason = reason }
    end
  end
  return report
end

-- Differential driver for finite, closed generated cases. The caller supplies
-- independent translators: reference(case) returns the oracle result;
-- production(case) returns the production observation. compare receives both.
function M.differential(spec)
  if type(spec) ~= 'table' or type(spec.cases) ~= 'table' then
    fail('facility differential expects a cases array', 2)
  end
  if type(spec.reference) ~= 'function' or type(spec.production) ~= 'function'
      or type(spec.compare) ~= 'function' then
    fail('facility differential requires reference, production and compare callbacks', 2)
  end
  for i = 1, #spec.cases do
    local case = spec.cases[i]
    local reference = spec.reference(case)
    local production = spec.production(case)
    local ok, err = pcall(spec.compare, case, reference, production)
    if not ok then
      fail((spec.name or 'facility differential') .. ' case ' .. tostring(i)
        .. ' failed: ' .. tostring(err), 2)
    end
  end
  return #spec.cases
end

return M
