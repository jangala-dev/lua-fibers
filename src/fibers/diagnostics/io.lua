-- Optional diagnostics facade over the core no-op I/O observation hook.
-- Loading this module does not alter semantics. Call enable() to install the
-- first-party lifecycle observer, or install(observer) for an application one.

local Audit = require('fibers.internal.io_audit')

function Audit.enable(observer)
  observer = observer or require('fibers.diagnostics.io_observer')
  Audit.install(observer)
  return observer
end

return Audit
