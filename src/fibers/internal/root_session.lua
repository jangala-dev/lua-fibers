---Shared root Runtime/Scope lifecycle for standalone and embedded execution.

local Closure = require('fibers.closure')
local Protected = require('fibers.protected')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local ScopeOutcome = require('fibers.scope.outcome')

local ScopeResult = ScopeOutcome.Result
local RootSession = {}

function RootSession.create(opts)
  local label = opts.label or 'root'
  local runtime = Runtime.new(opts.runtime_options or { host = opts.host })
  local scope = Scope.new({
    runtime = runtime,
    closure = opts.closure or Closure.nursery({ name = label }),
  }):label(label)
  return runtime, scope
end

function RootSession.spawn_root(runtime, scope, fn, label, label_subject)
  local fiber
  fiber = runtime:_spawn_raw(function()
    fiber.root_result = scope:try_run(fn)
    return fiber.root_result
  end, scope, label_subject and scope or nil):label(label or 'root')
  return fiber
end

function RootSession.complete(runtime, scope, root_fiber, runtime_status, runtime_error)
  local ok, err = Protected.pcall(function()
    return runtime:_finalize()
  end)
  if not ok and runtime_error == nil then
    runtime_error = err
  end

  local result = root_fiber and root_fiber.root_result
  if runtime_error ~= nil then
    local closure_failures = ScopeOutcome.closure_failures(runtime_error)
    result = ScopeResult.fail({
      reason = 'runtime_error',
      primary = runtime_error,
      report = scope:_make_report(runtime_error, {}, {
        reason = 'runtime_error',
        closure_failures = closure_failures,
      }),
      closure_failures = closure_failures,
      runtime_status = runtime_status,
    })
  elseif result == nil then
    result = ScopeResult.fail({
      reason = 'runtime_pending',
      primary = runtime_status,
      report = scope:_make_report(runtime_status, {}, { reason = 'runtime_pending' }),
      runtime_status = runtime_status,
    })
  end

  result.runtime_status = runtime_status
  result.runtime = runtime
  result.scope = scope
  return result
end

return RootSession
