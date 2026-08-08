-- Structured reports and checked results for a lifetime boundary.

local Label = require('fibers.internal.label')

local unpack_ = table.unpack or unpack

local Report = {}
Report.__index = Report

local Result = {}
Result.__index = Result

local function is_tagged(value, tag)
  return type(value) == 'table' and value[tag] == true
end

function Report.new(scope, primary, secondaries, fields)
  local report = fields or {}
  local secondary = secondaries or {}
  local closure_failures = report.closure_failures or {}
  report._fibers_scope_report = true
  report.kind = report.kind or ((primary ~= nil or #secondary > 0 or report.reason ~= nil) and 'scope_failure' or 'scope_report')
  report.scope, report.scope_id = scope, scope and scope._fibers_id
  report.scope_label = scope and Label.describe(scope._lifetime or scope, scope._fibers_id or 'scope')
  report.primary, report.secondaries, report.secondary_count = primary, secondary, #secondary
  report.child_exits, report.child_failures = report.child_exits or {}, report.child_failures or {}
  report.closure_failures, report.closure_failure_count = closure_failures, #closure_failures
  return setmetatable(report, Report)
end

function Report.is(value) return is_tagged(value, '_fibers_scope_report') end

function Report:append(err)
  self.secondaries[#self.secondaries + 1] = err
  self.secondary_count = #self.secondaries
  return self
end

function Report:tostring()
  if self.message then return self.message end
  local parts = { 'scope ', tostring(self.scope_label or self.scope_id or '?') }
  if self.primary ~= nil or #self.secondaries > 0 or self.reason ~= nil then
    parts[#parts + 1] = ' failed'
  elseif #self.child_failures > 0 then
    parts[#parts + 1] = ' completed with '
    parts[#parts + 1] = tostring(#self.child_failures)
    parts[#parts + 1] = #self.child_failures == 1 and ' child failure' or ' child failures'
  else
    parts[#parts + 1] = ' completed'
  end
  if self.primary ~= nil then
    parts[#parts + 1] = ': '
    parts[#parts + 1] = tostring(self.primary)
  end
  if #self.secondaries > 0 then
    local errors = {}
    for i = 1, #self.secondaries do errors[i] = tostring(self.secondaries[i]) end
    parts[#parts + 1] = #self.secondaries == 1 and ' (secondary failure: ' or ' (secondary failures: '
    parts[#parts + 1] = table.concat(errors, '; ')
    parts[#parts + 1] = ')'
  end
  return table.concat(parts)
end
Report.__tostring = Report.tostring

function Result.ok(values, report)
  return setmetatable({ _fibers_scope_result = true, ok = true, values = values or { n = 0 }, report = report }, Result)
end

function Result.fail(fields)
  fields = fields or {}
  local closure_failures = fields.closure_failures or (fields.report and fields.report.closure_failures) or {}
  fields._fibers_scope_result, fields.ok = true, false
  fields.reason = fields.reason or 'scope_failed'
  fields.closure_failures, fields.closure_failure = closure_failures, closure_failures[1]
  return setmetatable(fields, Result)
end

function Result.is(value) return is_tagged(value, '_fibers_scope_result') end

function Result:unpack()
  if not self.ok then return nil, self.reason, self.report end
  return unpack_(self.values, 1, self.values.n or #self.values)
end

function Result:done_outcome()
  return { ok = self.ok == true, reason = self.reason, report = self.report }
end

function Result:raise()
  if self.ok then return self:unpack() end
  if type(self.primary) == 'table' and self.primary._fibers_cancelled == true then error(self.primary, 0) end
  error(self.report or self.primary or self.reason or 'scope failed', 0)
end

function Result:tostring()
  if self.ok then return 'scope ok' end
  if Report.is(self.report) then return self.report:tostring() end
  return tostring(self.primary or self.reason or 'scope failed')
end
Result.__tostring = Result.tostring

local Outcome = { Report = Report, Result = Result }

function Outcome.protected_exit(Exit, results)
  if results[1] then return Exit.returned(unpack_(results, 2, results.n)) end
  local err = results[2]
  if type(err) == 'table' and err._fibers_cancelled == true then return Exit.cancelled(err.reason, err.token) end
  return Exit.failed(err)
end

function Outcome.closure_failures(value, out, seen)
  out, seen = out or {}, seen or {}
  if type(value) ~= 'table' or seen[value] then return out end
  seen[value] = true
  if value._fibers_closure_failure == true then out[#out + 1] = value; return out end
  for _, values in ipairs({ value.closure_failures, value.secondaries }) do
    if type(values) == 'table' then
      for i = 1, #values do Outcome.closure_failures(values[i], out, seen) end
    end
  end
  for _, nested in ipairs({ value.report, value.primary, value.cause }) do
    Outcome.closure_failures(nested, out, seen)
  end
  return out
end

return Outcome
