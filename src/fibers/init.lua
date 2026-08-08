-- Root lifecycle and contextual operations for Fibers programs.
--
-- `run` and `try_run` establish a Runtime and root Scope. The remaining
-- operations are interpreted by the currently running fiber. Types,
-- constructors and option combinators live in their named modules.

local External = require('fibers.embed.external')
local Protected = require('fibers.protected')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local perform = require('fibers.perform')
local ScopeOutcome = require('fibers.scope.outcome')
local Execution = require('fibers.internal.execution')
local Contract = require('fibers.internal.contract')

local M = { perform = perform }

local RUNTIME_OPTION_KEYS = {
  instrumentation = true,
  quiet_deadlock = true,
  search_limit = true,
  search_total_limit = true,
  search_trail_limit = true,
  search_depth_limit = true,
  cycle_work_limit = true,
  cycle_focus_limit = true,
  choice_seed = true,
}

local TRY_RUN_OPTIONS = {
  host = true,
  now = true,
  label = true,
  closure = true,
  run = true,
  host_options = true,
  max_iterations = true,
}
for key in pairs(RUNTIME_OPTION_KEYS) do
  TRY_RUN_OPTIONS[key] = true
end

local function runtime_options(opts, host)
  local runtime_opts = { host = host }
  for key in pairs(RUNTIME_OPTION_KEYS) do
    if opts[key] ~= nil then
      runtime_opts[key] = opts[key]
    end
  end
  return runtime_opts
end

local function default_host(opts)
  if opts and opts.host then
    return opts.host
  end
  local host = require('fibers.embed.pure').new()
  if opts and opts.now then
    host.now = function(rt)
      return opts.now(rt)
    end
  end
  return host
end

function M.try_run(fn, opts)
  opts = Contract.options(opts, TRY_RUN_OPTIONS, 'fibers.try_run options', 2)
  if type(fn) ~= 'function' then
    error('fibers.try_run expects a function', 2)
  end
  local Closure = require('fibers.closure')
  local ScopeResult = ScopeOutcome.Result
  local host = default_host(opts)
  local rt = Runtime.new(runtime_options(opts, host))
  local root_label = opts.label or 'root'
  local scope = Scope.new({
    runtime = rt,
    closure = opts.closure or Closure.nursery({ name = root_label }),
  }):label(root_label)
  local result
  local runtime_status
  local ok, err = Protected.pcall(function()
    rt:_spawn_raw(function()
      result = scope:try_run(fn)
      return result
    end, scope, scope)
    runtime_status = External.drive(rt, {
      host = host,
      run = opts.run,
      host_options = opts.host_options,
      max_iterations = opts.max_iterations,
    })
  end)
  local finalised, finalise_err = Protected.pcall(function()
    return rt:_finalize()
  end)
  if ok and not finalised then
    ok, err = false, finalise_err
  end
  if ok and result then
    result.runtime_status = runtime_status
    result.runtime = rt
    result.scope = scope
    return result
  end
  if not ok then
    local closure_failures = ScopeOutcome.closure_failures(err)
    return ScopeResult.fail({
      reason = 'runtime_error',
      primary = err,
      report = scope:_make_report(err, {}, {
        reason = 'runtime_error',
        closure_failures = closure_failures,
      }),
      closure_failures = closure_failures,
      runtime_status = runtime_status,
    })
  end
  local pending = ScopeResult.fail({
    reason = 'runtime_pending',
    primary = runtime_status,
    report = scope:_make_report(runtime_status, {}, { reason = 'runtime_pending' }),
    runtime_status = runtime_status,
  })
  pending.runtime = rt
  pending.scope = scope
  return pending
end

function M.run(fn, opts)
  return M.try_run(fn, opts):raise()
end

function M.pcall(fn, ...)
  return Protected.pcall(fn, ...)
end

function M.xpcall(fn, handler, ...)
  return Protected.xpcall(fn, handler, ...)
end

function M.current_runtime()
  return Runtime.current()
end

local function current_scope()
  return Runtime.current_scope and Runtime.current_scope() or nil
end

function M.current_scope()
  return current_scope()
end

function M.now()
  local rt = Runtime.current()
  if not rt then
    error('fibers.now must be called from a running fiber', 2)
  end
  return rt:now()
end

function M.spawn(fn, opts)
  local scope = current_scope()
  if not scope or type(scope.spawn) ~= 'function' then
    error('fibers.spawn requires a current scope', 2)
  end
  return scope:spawn(fn, opts)
end

local unpack_ = table.unpack or unpack
local function pack(...)
  return { n = select('#', ...), ... }
end

-- Assert that fn completes without the current fiber relinquishing its
-- scheduler turn. Immediate performs are permitted; an operation which would
-- park the fiber or allow another fiber to run raises before that hand-off.
function M.without_suspension(fn, ...)
  if type(fn) ~= 'function' then
    error('fibers.without_suspension expects a function', 2)
  end
  local rt = Runtime.current()
  if not rt then
    error('fibers.without_suspension must be called from a running fiber', 2)
  end
  local token = rt:_enter_execution_contract({
    suspension = 'forbidden',
    kind = 'without_suspension',
    source = Execution.capture_source(2),
  })
  local result = pack(Protected.pcall(fn, ...))
  rt:_leave_execution_contract(token)
  if not result[1] then
    error(result[2], 0)
  end
  return unpack_(result, 2, result.n)
end

function M.mask(fn, ...)
  if type(fn) ~= 'function' then
    error('fibers.mask expects a function', 2)
  end
  local scope = current_scope()
  if not scope then
    return fn(...)
  end
  scope._mask_depth = (scope._mask_depth or 0) + 1
  local result = pack(Protected.pcall(fn, ...))
  scope._mask_depth = scope._mask_depth - 1
  if not result[1] then
    error(result[2], 0)
  end
  return unpack_(result, 2, result.n)
end

function M.try_scope(opts, fn)
  if type(opts) == 'function' then
    fn, opts = opts, nil
  end
  opts = Contract.options(opts, { closure = true, label = true }, 'fibers.try_scope options', 2)
  if type(fn) ~= 'function' then
    error('fibers.try_scope expects a function', 2)
  end
  local rt = Runtime.current()
  if not rt then
    error('fibers.try_scope must be called from a running fiber', 2)
  end
  local parent = current_scope()
  local scope = Scope.new({
    runtime = rt,
    parent = parent,
    closure = opts.closure or (parent and parent._lifetime._closure),
  })
  if opts.label ~= nil then scope:label(opts.label) end
  return scope:try_run(fn)
end

function M.scope(opts, fn)
  if type(opts) == 'function' then
    fn, opts = opts, {}
  end
  return M.try_scope(opts, fn):raise()
end

return M
