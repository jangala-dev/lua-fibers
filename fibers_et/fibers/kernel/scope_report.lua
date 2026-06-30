-- Structured scope exit reports.
--
-- A scope body may fail, and settlement may also fail while retiring owned
-- roots.  ScopeReport keeps those facts together so policy and supervisor code
-- can preserve the primary failure while still observing cleanup failures.

local ScopeReport = {}
ScopeReport.__index = ScopeReport

local function to_message(x)
  if x == nil then return nil end
  local ok, s = pcall(tostring, x)
  return ok and s or '<unprintable>'
end

function ScopeReport.new(scope, primary, secondaries, fields)
  fields = fields or {}
  local s = secondaries or {}
  return setmetatable({
    _fibers_scope_report = true,
    kind = fields.kind or 'scope_failure',
    scope = scope,
    scope_id = scope and scope._fibers_id,
    scope_name = scope and scope.name,
    primary = primary,
    secondaries = s,
    secondary_count = #s,
    phase = fields.phase or 'scope_exit',
    reason = fields.reason,
    message = fields.message,
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

function ScopeReport:primary_error()
  return self.primary
end

function ScopeReport:settlement_errors()
  return self.secondaries
end

function ScopeReport:tostring()
  if self.message then return self.message end
  local parts = {}
  parts[#parts + 1] = 'scope '
  parts[#parts + 1] = tostring(self.scope_name or self.scope_id or '?')
  parts[#parts + 1] = ' failed'
  if self.primary ~= nil then
    parts[#parts + 1] = ': '
    parts[#parts + 1] = to_message(self.primary)
  end
  if #self.secondaries > 0 then
    parts[#parts + 1] = ' (settlement failure'
    if #self.secondaries ~= 1 then parts[#parts + 1] = 's' end
    parts[#parts + 1] = ': '
    local msgs = {}
    for i = 1, #self.secondaries do msgs[#msgs + 1] = to_message(self.secondaries[i]) end
    parts[#parts + 1] = table.concat(msgs, '; ')
    parts[#parts + 1] = ')'
  end
  return table.concat(parts)
end

ScopeReport.__tostring = ScopeReport.tostring

return ScopeReport
