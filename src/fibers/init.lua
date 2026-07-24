-- Root lifecycle and contextual operations for Fibers programmes.
--
-- `run` and `try_run` establish a Runtime and root Scope. The remaining
-- operations are interpreted by the currently running fibre. Types,
-- constructors and option combinators live in their named modules.

local Protected = require('fibers.internal.protected')
local Runtime = require('fibers.runtime')
local Scope = require('fibers.scope')
local perform = require('fibers.perform')

local M = { perform = perform }

local function settlement_failures_from(err)
  if type(err) ~= 'table' then
    return {}
  end
  if err._fibers_settlement_failure == true then
    return { err }
  end
  if type(err.cause) == 'table' and err.cause._fibers_settlement_failure == true then
    return { err.cause }
  end
  return {}
end

local function runtime_options(opts, host)
  local runtime_opts = {}
  for key, value in pairs(opts or {}) do
    runtime_opts[key] = value
  end
  runtime_opts.host = host
  return runtime_opts
end

local function default_host(opts)
  if opts and opts.host then
    return opts.host
  end
  local host = require('fibers.host').pure()
  if opts and opts.now then
    host.now = function(rt)
      return opts.now(rt)
    end
  end
  return host
end

function M.try_run(fn, opts)
  opts = opts or {}
  if type(fn) ~= 'function' then
    error('fibers.try_run expects a function', 2)
  end
  local Policy = require('fibers.policy')
  local ScopeResult = require('fibers.scope.result')
  local host = default_host(opts)
  local rt = Runtime.new(runtime_options(opts, host))
  local scope = Scope.new(
    opts.name or 'root',
    { runtime = rt, policy = opts.policy or Policy.nursery({ name = opts.name or 'root' }) }
  )
  local result
  local runtime_status
  local ok, err = Protected.pcall(function()
    rt:spawn_raw(function()
      result = scope:try_run(fn)
      return result
    end, opts.name or 'root', scope)
    runtime_status = rt:drive({
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
    local settlement_failures = settlement_failures_from(err)
    return ScopeResult.fail({
      reason = 'runtime_error',
      primary = err,
      report = scope:_make_report(err, {}, {
        reason = 'runtime_error',
        settlement_failures = settlement_failures,
      }),
      settlement_failures = settlement_failures,
      runtime_status = runtime_status,
    })
  end
  return ScopeResult.fail({
    reason = 'runtime_pending',
    primary = runtime_status,
    report = scope:_make_report(runtime_status, {}, { reason = 'runtime_pending' }),
    runtime_status = runtime_status,
  })
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
    error('fibers.now must be called from a running fibre', 2)
  end
  return rt:now()
end

function M.spawn_raw(fn, name)
  local rt = Runtime.current()
  if not rt then
    error('fibers.spawn_raw must be called from a running fibre', 2)
  end
  local scope = current_scope()
  if scope then
    local policy = scope.policy
    local allowed = policy and policy.permit_unstructured == true
    if policy and type(policy.allow_unstructured) == 'function' then
      allowed = policy:allow_unstructured(scope, fn, name) ~= false
    end
    if not allowed then
      error(
        'unstructured spawn is prohibited by the current scope policy; '
          .. 'use fibers.spawn or Runtime:spawn_raw',
        2
      )
    end
  end
  return rt:spawn_raw(fn, name, scope)
end

function M.spawn(fn, name)
  local scope = current_scope()
  if not scope or type(scope.spawn) ~= 'function' then
    error('fibers.spawn requires a current scope; use Runtime:spawn_raw for unstructured fibres', 2)
  end
  return scope:spawn(fn, name)
end

local unpack_ = table.unpack or unpack
local function pack(...)
  return { n = select('#', ...), ... }
end

function M.mask(fn, ...)
  if type(fn) ~= 'function' then
    error('fibers.mask expects a function', 2)
  end
  local scope = current_scope()
  if not scope then
    return fn(...)
  end
  scope.mask_depth = (scope.mask_depth or 0) + 1
  local result = pack(Protected.pcall(fn, ...))
  scope.mask_depth = scope.mask_depth - 1
  if not result[1] then
    error(result[2], 0)
  end
  return unpack_(result, 2, result.n)
end

function M.try_scope(opts, fn)
  if type(opts) == 'function' then
    fn, opts = opts, {}
  end
  opts = opts or {}
  if type(fn) ~= 'function' then
    error('fibers.try_scope expects a function', 2)
  end
  local rt = Runtime.current()
  if not rt then
    error('fibers.try_scope must be called from a running fibre', 2)
  end
  local parent = current_scope()
  local scope = Scope.new(
    opts.name or 'scope',
    { runtime = rt, parent = parent, policy = opts.policy or (parent and parent.policy) }
  )
  return scope:try_run(fn)
end

function M.scope(opts, fn)
  if type(opts) == 'function' then
    fn, opts = opts, {}
  end
  return M.try_scope(opts or {}, fn):raise()
end

return M
