-- Structured reports and checked results for a lifetime boundary.

local unpack_ = table.unpack or unpack

local Report = {}
Report.__index = Report

local Result = {}
Result.__index = Result

local function is_tagged(value, tag)
  return type(value) == 'table' and value[tag] == true
end

local function message(value)
  return value == nil and nil or tostring(value)
end

function Report.new(scope, primary, secondaries, fields)
  fields = fields or {}
  local secondary = secondaries or {}
  local closure_failures = fields.closure_failures or {}
  return setmetatable({
    _fibers_scope_report = true,
    kind = fields.kind
      or ((primary ~= nil or #secondary > 0 or fields.reason ~= nil) and 'scope_failure' or 'scope_report'),
    scope = scope,
    scope_id = scope and scope._fibers_id,
    scope_name = scope and scope.name,
    primary = primary,
    secondaries = secondary,
    secondary_count = #secondary,
    reason = fields.reason,
    closure_reason = fields.closure_reason,
    message = fields.message,
    cause = fields.cause,
    child_exits = fields.child_exits or {},
    child_failures = fields.child_failures or {},
    body_exit = fields.body_exit,
    closure_failures = closure_failures,
    closure_failure_count = #closure_failures,
  }, Report)
end

function Report.is(value)
  return is_tagged(value, '_fibers_scope_report')
end

function Report:append(err)
  self.secondaries[#self.secondaries + 1] = err
  self.secondary_count = #self.secondaries
  return self
end

function Report:tostring()
  if self.message then
    return self.message
  end
  local parts = { 'scope ', tostring(self.scope_name or self.scope_id or '?') }
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
    parts[#parts + 1] = message(self.primary)
  end
  if #self.secondaries > 0 then
    local errors = {}
    for i = 1, #self.secondaries do
      errors[i] = message(self.secondaries[i])
    end
    parts[#parts + 1] = #self.secondaries == 1 and ' (secondary failure: ' or ' (secondary failures: '
    parts[#parts + 1] = table.concat(errors, '; ')
    parts[#parts + 1] = ')'
  end
  return table.concat(parts)
end
Report.__tostring = Report.tostring

local function copy_values(values)
  local count = values and (values.n or #values) or 0
  local out = { n = count }
  for i = 1, count do
    out[i] = values[i]
  end
  return out
end

function Result.ok(values, report)
  return setmetatable(
    { _fibers_scope_result = true, ok = true, values = copy_values(values), report = report },
    Result
  )
end

function Result.fail(fields)
  fields = fields or {}
  local closure_failures = fields.closure_failures or (fields.report and fields.report.closure_failures) or {}
  return setmetatable({
    _fibers_scope_result = true,
    ok = false,
    reason = fields.reason or 'scope_failed',
    primary = fields.primary,
    report = fields.report,
    runtime_status = fields.runtime_status,
    closure_failures = closure_failures,
    closure_failure = closure_failures[1],
  }, Result)
end

function Result.is(value)
  return is_tagged(value, '_fibers_scope_result')
end

function Result:unpack()
  if not self.ok then
    return nil, self.reason, self.report
  end
  return unpack_(self.values, 1, self.values.n or #self.values)
end

function Result:done_outcome()
  return { ok = self.ok == true, reason = self.reason, report = self.report }
end

function Result:raise()
  if self.ok then
    return self:unpack()
  end
  if type(self.primary) == 'table' and self.primary._fibers_cancelled == true then
    error(self.primary, 0)
  end
  error(self.report or self.primary or self.reason or 'scope failed', 0)
end

function Result:tostring()
  if self.ok then
    return 'scope ok'
  end
  if Report.is(self.report) then
    return self.report:tostring()
  end
  return tostring(self.primary or self.reason or 'scope failed')
end
Result.__tostring = Result.tostring

local Outcome = { Report = Report, Result = Result }

function Outcome.closure_failures(value)
  if type(value) ~= 'table' then
    return {}
  end
  if value._fibers_closure_failure == true then
    return { value }
  end
  local cause = value.cause
  return type(cause) == 'table' and cause._fibers_closure_failure == true and { cause } or {}
end

return Outcome
