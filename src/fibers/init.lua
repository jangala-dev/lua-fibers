-- Fibers application-facing concurrency language.
--
-- Options are inert descriptions. Resource methods ending in `_op` build
-- them; perform is the single execution boundary. More specialised resources,
-- lifetime types, hosts and embedding interfaces live in their named modules.

local M = {}

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Effect = require('fibers.lifetime.effect')
local Protected = require('fibers.internal.protected')
local Policy = require('fibers.policy')
local Sleep = require('fibers.sleep')
local Host = require('fibers.host')
local Runner = require('fibers.runner')
local Scope = require('fibers.scope')
local ScopeResult = require('fibers.scope.result')

M.sleep_op = Sleep.sleep_op
M.sleep_until_op = Sleep.sleep_until_op

M.always = Op.always
M.never = Op.never
M.choice = Op.choice
M.named_choice = Op.named_choice
M.all = Op.all
M.named_all = Op.named_all
M.tensor = Op.tensor
M.after_commit = Effect.after_commit

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

function M.perform(op)
  local rt = Runtime.current()
  if not rt then
    error('fibers.perform must be called from a running fiber', 2)
  end
  local scope = current_scope()
  if scope and type(scope.perform) == 'function' then
    return scope:perform(op)
  end
  return rt:perform(op)
end

function M.spawn_raw(fn, name)
  local rt = Runtime.current()
  if not rt then
    error('fibers.spawn_raw must be called from a running fiber; use fibers.run to start a root fiber', 2)
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
    error('fibers.spawn requires a current scope; use fibers.spawn_raw for unstructured fibres', 2)
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
  local r = pack(Protected.pcall(fn, ...))
  scope.mask_depth = scope.mask_depth - 1
  if not r[1] then
    error(r[2], 0)
  end
  return unpack_(r, 2, r.n)
end

M.uninterruptible = M.mask

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
    error('fibers.try_scope must be called from a running fiber', 2)
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

local function runtime_options(opts, host)
  local rt_opts = {}
  for k, v in pairs(opts or {}) do
    rt_opts[k] = v
  end
  rt_opts.host = host
  return rt_opts
end

local function default_host(opts)
  if opts and opts.host then
    return opts.host
  end
  local host = Host.pure()
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
  local host = default_host(opts)
  local rt = Runtime.new(runtime_options(opts, host))
  local scope = Scope.new(
    opts.name or 'root',
    { runtime = rt, policy = opts.policy or Policy.nursery({ name = opts.name or 'root' }) }
  )
  local result
  local runner_status
  local ok, err = Protected.pcall(function()
    rt:spawn_raw(function()
      result = scope:try_run(fn)
      return result
    end, opts.name or 'root', scope)
    runner_status = Runner.run(rt, {
      host = host,
      run = opts.run,
      host_options = opts.host_options,
      max_iterations = opts.max_iterations,
    })
    if not result and runner_status and runner_status.tag == 'found' then
      runner_status = Runner.run(rt, {
        host = host,
        run = opts.run,
        host_options = opts.host_options,
        max_iterations = opts.max_iterations,
      })
    end
  end)
  if ok and result then
    result.runtime_status = runner_status
    result.runtime = rt
    result.scope = scope
    return result
  end
  if not ok then
    return ScopeResult.fail({
      reason = 'runtime_error',
      primary = err,
      report = scope:_make_report(err, {}, { reason = 'runtime_error' }),
      runtime_status = runner_status,
    })
  end
  return ScopeResult.fail({
    reason = 'runtime_pending',
    primary = runner_status,
    report = scope:_make_report(runner_status, {}, { reason = 'runtime_pending' }),
    runtime_status = runner_status,
  })
end

function M.run(fn, opts)
  return M.try_run(fn, opts):raise()
end

return M
