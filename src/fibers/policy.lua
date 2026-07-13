-- Scope boundary policies.
--
-- Policies own boundary decisions.  The supplied driver offers a Region-backed
-- live monitor, atomic closure, masked settlement and result construction.

local ScopeResult = require('fibers.scope.result')

local Policy = {}

local Nursery = {}
Nursery.__index = Nursery

function Policy.nursery(opts)
  opts = opts or {}
  return setmetatable({
    name = opts.name or 'nursery',
    permit_unstructured = opts.allow_unstructured == true,
    permit_outward_move = opts.allow_outward_move ~= false,
    permit_admission = opts.allow_admission ~= false,
  }, Nursery)
end

function Nursery:try_run(scope, fn, driver)
  return driver.run(scope, fn, self)
end

function Nursery:on_child_exit(_scope, _state, _task, exit)
  if type(exit) == 'table' and exit.tag == 'failed' then
    return { fail_boundary = true, seal = true, cancel_body = true, cancel_children = true }
  end
  return {}
end

function Nursery:on_cancel_requested(_scope, _state, reason)
  return { seal = true, cancel_children = true, reason = reason }
end

function Nursery:on_body_exit(_scope, _state, ok, primary)
  if ok then
    return { seal = true, cancel_children = false }
  end
  return { seal = true, cancel_children = true, reason = primary }
end

local Supervisor = {}
Supervisor.__index = Supervisor

function Policy.supervisor(opts)
  opts = opts or {}
  local mode = opts.child_failure or 'fail_at_exit'
  if mode ~= 'fail_at_exit' and mode ~= 'collect' and mode ~= 'ignore' then
    error('supervisor child_failure must be fail_at_exit, collect, or ignore', 2)
  end
  return setmetatable({
    name = opts.name or 'supervisor',
    child_failure = mode,
    permit_unstructured = opts.allow_unstructured == true,
    permit_outward_move = opts.allow_outward_move ~= false,
    permit_admission = opts.allow_admission ~= false,
  }, Supervisor)
end

function Supervisor:try_run(scope, fn, driver)
  return driver.run(scope, fn, self)
end

function Supervisor:on_child_exit(_scope, state, _task, exit)
  if type(exit) == 'table' and exit.tag == 'failed' and self.child_failure == 'fail_at_exit' then
    if not state.first_child_failure then
      state.first_child_failure = state.child_failures[#state.child_failures]
    end
  end
  return {}
end

function Supervisor:on_cancel_requested(_scope, _state, reason)
  return { seal = true, cancel_children = true, reason = reason }
end

function Supervisor:on_body_exit(_scope, _state, ok, primary)
  if ok then
    return { seal = true, cancel_children = false }
  end
  return { seal = true, cancel_children = true, reason = primary }
end

function Supervisor:result(scope, state, account)
  if self.child_failure == 'collect' and account.body_ok and #account.settlement_failures == 0 then
    return ScopeResult.ok(
      (function()
        local values = { n = math.max((account.body_results.n or #account.body_results) - 1, 0) }
        for i = 1, values.n do
          values[i] = account.body_results[i + 1]
        end
        return values
      end)(),
      scope:_make_report(nil, {}, account.fields)
    )
  elseif
    self.child_failure == 'ignore'
    and account.body_ok
    and #account.settlement_failures == 0
  then
    local values = { n = math.max((account.body_results.n or #account.body_results) - 1, 0) }
    for i = 1, values.n do
      values[i] = account.body_results[i + 1]
    end
    return ScopeResult.ok(values, scope:_make_report(nil, {}, account.fields))
  end
  return nil
end

return Policy
