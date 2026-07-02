-- ScopeResult: checked outcome of a lifetime boundary.

local ScopeReport = require('fibers.kernel.scope_report')
local unpack_ = table.unpack or unpack

local ScopeResult = {}
ScopeResult.__index = ScopeResult

local function copy_values(values)
  local out = { n = values and (values.n or #values) or 0 }
  for i = 1, out.n do out[i] = values[i] end
  return out
end

function ScopeResult.ok(values, report)
  return setmetatable({ _fibers_scope_result = true, ok = true, values = copy_values(values), report = report }, ScopeResult)
end

function ScopeResult.fail(fields)
  fields = fields or {}
  return setmetatable({
    _fibers_scope_result = true,
    ok = false,
    reason = fields.reason or 'scope_failed',
    primary = fields.primary,
    report = fields.report,
    runtime_status = fields.runtime_status,
  }, ScopeResult)
end

function ScopeResult.is(x) return type(x) == 'table' and x._fibers_scope_result == true end
function ScopeResult:unpack() if not self.ok then return nil, self.reason, self.report end; return unpack_(self.values, 1, self.values.n or #self.values) end
function ScopeResult:done_outcome() return { ok = self.ok == true, reason = self.reason, report = self.report } end
function ScopeResult:raise()
  if self.ok then return self:unpack() end
  if type(self.primary) == 'table' and self.primary._fibers_cancelled == true then
    error(self.primary, 0)
  end
  error(self.report or self.primary or self.reason or 'scope failed', 0)
end
function ScopeResult:tostring() if self.ok then return 'scope ok' end; if self.report and ScopeReport.is(self.report) then return self.report:tostring() end; return tostring(self.primary or self.reason or 'scope failed') end
ScopeResult.__tostring = ScopeResult.tostring

return ScopeResult
