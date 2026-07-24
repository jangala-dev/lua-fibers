-- Structured scope boundary reports.
--
-- A scope body may fail, and settlement may also fail while retiring owned
-- roots. ScopeReport keeps those facts together without becoming lifecycle
-- status.

local ScopeReport = {}
ScopeReport.__index = ScopeReport

local function to_message(x)
  if x == nil then
    return nil
  end
  return tostring(x)
end

function ScopeReport.new(scope, primary, secondaries, fields)
  fields = fields or {}
  local s = secondaries or {}
  return setmetatable({
    _fibers_scope_report = true,
    kind = fields.kind
      or ((primary ~= nil or #s > 0 or fields.reason ~= nil) and 'scope_failure' or 'scope_report'),
    scope = scope,
    scope_id = scope and scope._fibers_id,
    scope_name = scope and scope.name,
    primary = primary,
    secondaries = s,
    secondary_count = #s,
    reason = fields.reason,
    closure_reason = fields.closure_reason,
    message = fields.message,
    cause = fields.cause,
    child_exits = fields.child_exits or {},
    child_failures = fields.child_failures or {},
    body_exit = fields.body_exit,
    settlement_failures = fields.settlement_failures or {},
    settlement_failure_count = #(fields.settlement_failures or {}),
  }, ScopeReport)
end

function ScopeReport.is(x)
  return type(x) == 'table' and x._fibers_scope_report == true
end

function ScopeReport:append(err)
  self.secondaries[#self.secondaries + 1] = err
  self.secondary_count = #self.secondaries
  return self
end

function ScopeReport:tostring()
  if self.message then
    return self.message
  end
  local parts = {}
  parts[#parts + 1] = 'scope '
  parts[#parts + 1] = tostring(self.scope_name or self.scope_id or '?')
  local failed = self.primary ~= nil or #self.secondaries > 0 or self.reason ~= nil
  if failed then
    parts[#parts + 1] = ' failed'
  elseif #self.child_failures > 0 then
    parts[#parts + 1] = ' completed with '
    parts[#parts + 1] = tostring(#self.child_failures)
    parts[#parts + 1] = ' child failure'
    if #self.child_failures ~= 1 then
      parts[#parts + 1] = 's'
    end
  else
    parts[#parts + 1] = ' completed'
  end
  if self.primary ~= nil then
    parts[#parts + 1] = ': '
    parts[#parts + 1] = to_message(self.primary)
  end
  if #self.secondaries > 0 then
    parts[#parts + 1] = ' (secondary failure'
    if #self.secondaries ~= 1 then
      parts[#parts + 1] = 's'
    end
    parts[#parts + 1] = ': '
    local msgs = {}
    for i = 1, #self.secondaries do
      msgs[#msgs + 1] = to_message(self.secondaries[i])
    end
    parts[#parts + 1] = table.concat(msgs, '; ')
    parts[#parts + 1] = ')'
  end
  return table.concat(parts)
end

ScopeReport.__tostring = ScopeReport.tostring

return ScopeReport
