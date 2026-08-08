-- Scope: the child-admission and custody capability of one Lifetime.
--
-- Scope contains no custody, cancellation, sealing or outcome state. Those
-- facts belong to its Runtime-local Lifetime node.

local Op = require('fibers.op')
local Rendezvous = require('fibers.resource.rendezvous')
local Task = require('fibers.task')
local Grant = require('fibers.grant')
local Runtime = require('fibers.runtime')
local Protected = require('fibers.protected')
local ScopeOutcome = require('fibers.scope.outcome')
local ScopeReport, ScopeResult = ScopeOutcome.Report, ScopeOutcome.Result
local Closure = require('fibers.closure')
local ScopeClosure = require('fibers.scope.closure')
local Lifetime = require('fibers.lifetime')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local unpack_ = table.unpack or unpack
local function pack(...)
  return { n = select('#', ...), ... }
end

local Scope = {}
Scope.__index = Scope

local next_id = 0

local function is_scope(x)
  return type(x) == 'table' and x._fibers_scope == true
end

local function target_scope(target)
  return is_scope(target) and target or nil
end

local function require_closure_permission(scope, field, action)
  local closure = scope._lifetime._closure
  if closure and closure[field] == false then
    error((action or field) .. ' denied by scope Closure', 3)
  end
end

local function item_kind(item)
  local life = Lifetime.of(item)
  if not life then return nil end
  return life._has_body and 'task' or 'resource'
end

local function new_offers()
  return Rendezvous.new()
end

local SCOPE_OPTIONS = { parent = true, closure = true, runtime = true, lifetime = true, label = true }

function Scope.new(opts)
  opts = Contract.options(opts, SCOPE_OPTIONS, 'Scope.new options', 2)
  next_id = next_id + 1
  local id = 'scope-' .. tostring(next_id)
  if opts.parent ~= nil and not is_scope(opts.parent) then
    error('Scope.new expects opts.parent to be a Scope', 2)
  end
  local lifetime = opts.lifetime
  if lifetime ~= nil and not Lifetime.is(lifetime) then
    error('Scope.new expects opts.lifetime to be a Lifetime', 2)
  end
  if not lifetime then
    lifetime = Lifetime.new({
      parent = opts.parent and opts.parent._lifetime or nil,
      closure = opts.closure,
      standalone_boundary = true,
      label = opts.label,
    })
  end
  if opts.runtime then lifetime:_bind_runtime(opts.runtime) end
  lifetime._closure = Closure.combine(lifetime._closure, Closure.propagation(opts.closure))
  lifetime._offers = lifetime._offers or new_offers()
  Label.child(lifetime._offers, lifetime, 'offers')
  return setmetatable({
    _mask_depth = 0,
    _lifetime = lifetime,
    _fibers_id = id,
    _fibers_scope = true,
  }, Scope)
end


function Scope.for_lifetime(lifetime)
  if not Lifetime.is(lifetime) then
    error('Scope.for_lifetime expects a Lifetime', 2)
  end
  next_id = next_id + 1
  return setmetatable({
    _mask_depth = 0,
    _lifetime = lifetime,
    _fibers_id = 'scope-view-' .. tostring(next_id),
    _fibers_scope = true,
  }, Scope)
end

function Scope:parent_scope()
  local lifetime = self._lifetime
  local parent
  if lifetime._runtime then
    parent = lifetime._runtime:_lifetime_store():_custodian(lifetime)
  end
  parent = parent or lifetime:_construction_parent_node()
  if not parent or parent == lifetime then return nil end
  return Scope.for_lifetime(parent)
end

function Scope:lifetime()
  return self._lifetime
end

function Scope:label(...)
  if select('#', ...) == 0 then
    return Label.get(self._lifetime)
  end
  Label.set(self._lifetime, select(1, ...), 2)
  return self
end

function Scope:diagnostic_label()
  return Label.describe(self._lifetime, self._lifetime._fibers_id or self._fibers_id)
end


function Scope:_bind_runtime(runtime)
  runtime = runtime or self._lifetime._runtime or Runtime.current()
  if not runtime then error('Scope requires a current Runtime', 2) end
  local parent = self:parent_scope()
  if parent then parent:_bind_runtime(runtime) end
  self._lifetime:_bind_runtime(runtime)
  return runtime
end

function Scope:_store()
  return self:_bind_runtime():_lifetime_store()
end

function Scope:admit_op(value)
  require_closure_permission(self, 'permit_admission', 'admission')
  local node = Lifetime.of(value)
  if not node then
    error('Scope:admit_op expects a value carrying a dormant Lifetime', 2)
  end
  local runtime = self:_bind_runtime()
  node:_assert_runtime_compatible(runtime)
  return runtime:_lifetime_store():admit_op(self, node):map(function()
    return value
  end)
end

function Scope:perform(op)
  local rt = self._lifetime._runtime or Runtime.current()
  if not rt then
    error('Scope:perform requires a current runtime or scope runtime', 2)
  end
  local token
  if (self._mask_depth or 0) <= 0 then
    token = self._lifetime._interrupt
  end
  return rt:_perform_current(op, token, false)
end

function Scope:mask(fn, ...)
  if type(fn) ~= 'function' then
    error('Scope:mask expects a function', 2)
  end
  self._mask_depth = (self._mask_depth or 0) + 1
  local r = pack(Protected.pcall(fn, ...))
  self._mask_depth = self._mask_depth - 1
  if not r[1] then
    error(r[2], 0)
  end
  return unpack_(r, 2, r.n)
end

function Scope:_run_child_body(fn, task, opts)
  opts = opts or {}
  if not task or not task._lifetime then
    error('Scope:_run_child_body expects a Task Lifetime', 2)
  end
  local child = Scope.new({
    parent = self,
    closure = opts.closure or self._lifetime._closure,
    runtime = self._lifetime._runtime or Runtime.current(),
    lifetime = task._lifetime,
  })
  -- ScopeClosure owns publication for Scope-backed Tasks. The body-exit hook
  -- runs exactly once, immediately after the protected user body returns and
  -- before descendant retirement begins. The outer Task runner verifies that
  -- this publication happened; it never republishes as a fallback.
  return ScopeClosure.run(child, function(s)
    return fn(s, task)
  end, child._lifetime._closure or {}, function(results, runtime)
    task:_publish_protected_body_result(results, runtime)
  end):raise()
end

function Scope:spawn_op(fn, opts)
  if type(fn) ~= 'function' then
    error('Scope:spawn_op expects a function', 2)
  end
  opts = Contract.options(opts, { label = true, closure = true }, 'Scope:spawn_op options', 2)
  local parent = self
  local task = Task._new(function(task_handle)
    return parent:_run_child_body(fn, task_handle, opts)
  end, self, {
    label = opts.label,
    closure = Closure.running(Closure.propagation(opts.closure or self._lifetime._closure)),
    body_result_owner = 'scope',
  })
  return self
    :admit_op(task)
    :and_then(task:spawn_effect_op())
    :map(function()
      return task
    end)
end

function Scope:spawn(fn, opts)
  return self:perform(self:spawn_op(fn, opts))
end

function Scope:move_op(item, target)
  if Grant.is(item) and not Grant._is_transferable(item) then
    error('Grant is not transferable', 2)
  end
  local r = target_scope(target)
  if not r then
    error('Scope:move_op expects a target Scope', 2)
  end
  require_closure_permission(self, 'permit_outward_move', 'outward movement')
  return self:_store():move_op(self, item, r):map(function()
    return item
  end)
end

function Scope:offer_op(item, target, terms)
  local target_sc = target_scope(target)
  if not target_sc then
    error('Scope:offer_op expects a target Scope', 2)
  end
  local offer = {
    from_scope = self,
    to_scope = target_sc,
    item = item,
    item_kind = item_kind(item),
    terms = terms,
  }
  local put_offer = target_sc._lifetime._offers:put_op(offer)
  return self:move_op(item, target_sc):and_then(put_offer:map(function()
      return offer
    end))
end

function Scope:accept_op(filter)
  if filter == nil then
    return self._lifetime._offers:get_op()
  end
  if type(filter) ~= 'function' then
    error('Scope:accept_op filter must be a function', 2)
  end
  return self._lifetime._offers:get_op():and_then(Op.guard(function(offer)
    if filter(offer) then
      return Op.always(offer)
    end
    -- Rejection rejects this possible world.  It must not consume an unrelated
    -- offer and loop, because the custody transfer itself is part of the same committed
    -- transaction.
    return Op.never()
  end))
end

local function phase_live(record)
  return record ~= nil and record.phase == 'live'
end

local function grant_can_op(scope, item, right)
  local subject_lifetime = Lifetime.require(item, 3)
  return scope:_store():roots_op(scope):and_then(Op.guard(function(items)
    local function scan(i)
      if i > #items then
        return Op.never()
      end
      local b = items[i]
      if Grant.is(b) and Grant._subject_lifetime(b) == subject_lifetime and b:has_right(right) then
        return Op.each({
          scope:_store():record_op(scope, b),
          scope:_store():active_op(subject_lifetime),
        }):and_then(Op.guard(function(rows)
          local record = rows[1][1]
          local subject_active = rows[2][1]
          if phase_live(record) and subject_active then
            return Op.always(item, { kind = 'grant', grant = b, right = right })
          end
          return scan(i + 1)
        end))
      end
      return scan(i + 1)
    end
    return scan(1)
  end))
end


function Scope:can_op(item, right)
  right = right or 'use'
  return self:_store()
    :custody_can_op(self, item, right, { allow_closing = (self._closure_depth or 0) > 0 })
    :and_then(Op.guard(function(ok, phase)
      if ok then
        local kind = phase == 'closing' and 'closure' or 'custody'
        return Op.always(item, { kind = kind, scope = self, right = right })
      end
      local granted = grant_can_op(self, item, right)
      local parent = self:parent_scope()
      if parent then
        -- Child scopes inherit authority to use live obligations held by their
        -- ancestors. Custody does not move; ordinary use is delegated down the
        -- lifetime tree while Grants add non-custodial authority independently.
        granted = granted:or_else(parent:can_op(item, right))
      end
      return granted
    end))
end

function Scope:grant_op(item, holder, rights, opts)
  if not is_scope(holder) then
    error('Scope:grant_op expects a holder Scope', 2)
  end
  opts = Contract.options(opts, { label = true, meta = true, terms = true }, 'Scope:grant_op options', 2)
  local runtime = self:_bind_runtime()
  holder:_bind_runtime(runtime)
  if holder._lifetime._runtime ~= runtime then
    error('Scope:grant_op requires both Scopes to belong to the same Runtime', 2)
  end
  local grant = Grant._new(self, holder, item, rights, {
    label = opts.label,
    meta = opts.meta,
    terms = opts.terms,
  })
  local ops = {}
  -- Version 1 keeps Grant issuance structural: only the current custodian may
  -- create a Grant. Authority received through another Grant may be exercised
  -- by descendants, but it cannot be copied onwards implicitly.
  local delegated = Grant._right_list(grant)
  for i = 1, #delegated do
    local right = delegated[i]
    ops[#ops + 1] = self:_store():custody_can_op(self, item, right):and_then(Op.guard(function(ok)
      return ok and Op.always(true) or Op.never()
    end))
  end
  return Op.each(ops)
    :and_then(holder:admit_op(grant))
    :map(function()
      return grant
    end)
end

function Scope:close_op(item, reason)
  return Closure.close_op(self, item, reason or 'closed')
end

function Scope:_request_cancel_op(reason)
  return self._lifetime:request_cancel_op(reason)
end

function Scope:request_cancel_op(reason)
  return ScopeClosure.request_cancel_op(self, reason)
end

function Scope:cancel_requested_op()
  return self._lifetime:cancel_requested_op()
end

function Scope:_running_children_op()
  return self:_store():roots_op(self):map(function(roots)
    local tasks = {}
    for i = 1, #roots do
      local life = Lifetime.of(roots[i])
      if life and life._has_body then tasks[#tasks + 1] = life end
    end
    return { tasks = tasks, roots = roots }
  end)
end

function Scope:begin_close_op(reason, opts)
  opts = Contract.options(opts, { cancel_body = true, cancel_children = true }, 'Scope:begin_close_op options', 2)
  Contract.optional_boolean(opts.cancel_body, 'Scope:begin_close_op cancel_body', 2)
  Contract.optional_boolean(opts.cancel_children, 'Scope:begin_close_op cancel_children', 2)
  return self:_running_children_op():and_then(Op.guard(function(snapshot)
    local ops = { self._lifetime:request_close_op(reason), self:seal_op(reason) }
    if opts.cancel_body ~= false then
      ops[#ops + 1] = self:_request_cancel_op(reason)
    end
    if opts.cancel_children ~= false then
      for i = 1, #snapshot.tasks do
        ops[#ops + 1] = snapshot.tasks[i]:request_cancel_op(reason)
      end
    end
    return Op.each(ops):map(function()
      return snapshot
    end)
  end))
end

function Scope:seal_op(_reason)
  return self:_store():seal_op(self):or_else(Op.always(true)):map(function()
    return self
  end)
end

local function lifetime_sealed_op(scope)
  return scope:_store():status_op(scope):and_then(Op.guard(function(status)
    if status.sealed then
      return Op.always(true)
    end
    return scope:_store():changed_op(scope, status.version):and_then(Op.guard(function()
      return lifetime_sealed_op(scope)
    end))
  end))
end

function Scope:sealed_op()
  return lifetime_sealed_op(self):map(function()
    return self
  end)
end

function Scope:_mark_done_op(result)
  local scope, lifetime = self, self._lifetime
  local unresolved = ScopeResult.is(result)
    and result.reason == 'closure_failed'
    and result.closure_failures
    and #result.closure_failures > 0
  local phase_op
  if unresolved then
    phase_op = lifetime:_mark_closure_failed_op(result.primary, result.reason)
  else
    phase_op = lifetime:_mark_closed_op(result.reason)
  end
  return Op.each({ phase_op, lifetime:publish_outcome_op(result) }):map(function()
    return ScopeResult.is(result) and result:done_outcome() or result, scope
  end)
end

function Scope:done_op()
  return self._lifetime:outcome_op():map(function(result)
    return ScopeResult.is(result) and result:done_outcome() or result
  end)
end

function Scope:has_custody_op(item)
  return self:_store():has_custody_op(self, item)
end
function Scope:_make_report(primary, secondaries, fields)
  return ScopeReport.new(self, primary, secondaries, fields)
end

function Scope:try_run(fn)
  return ScopeClosure.try_run(self, fn)
end

function Scope:run(fn)
  return self:try_run(fn):raise()
end

Scope.Report = ScopeReport
Scope.Result = ScopeResult
Scope.is = is_scope
function Scope.require(value, label)
  if is_scope(value) then return value end
  error((label or 'value') .. ' must be a Scope', 2)
end
function Scope.is_report(x)
  return ScopeReport.is(x)
end
return Scope
