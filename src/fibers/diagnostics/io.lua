-- Optional observer for external-resource lifecycle events.
-- Production semantics do not depend on an observer being installed.

local Audit = {}
local observer

function Audit.install(value)
  observer = value
  return value
end

local function event(name, ...)
  local fn = observer and observer[name]
  if fn then
    return fn(...)
  end
end

for _, name in ipairs({
  'created',
  'bind',
  'hold',
  'transfer',
  'release',
  'closing',
  'closed',
  'register',
  'retire',
  'service',
  'control',
  'stale_ready',
}) do
  Audit[name] = function(...)
    return event(name, ...)
  end
end

function Audit.record(value)
  return observer and observer.record and observer.record(value) or nil
end

function Audit.snapshot(rt, opts)
  if observer and observer.snapshot then
    return observer.snapshot(rt, opts)
  end
  return { counts = {}, items = {}, stats = nil }
end

function Audit.active(rt)
  return Audit.snapshot(rt).items
end

function Audit.assert_clean(rt, opts)
  if observer and observer.assert_clean then
    return observer.assert_clean(rt, opts)
  end
  return true
end

function Audit.reset_for_test()
  if observer and observer.reset_for_test then
    return observer.reset_for_test()
  end
end

return Audit
