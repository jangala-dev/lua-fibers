-- Scope: the child-admission and custody capability of one Lifetime.
--
-- Scope contains no custody, cancellation, sealing or outcome state. Those
-- facts belong to its Runtime-local Lifetime node.

local Op = require('fibers.op')
local Facility = require('fibers.resource.authoring')
local Completion = require('fibers.resource.completion')
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
  local policy = scope._role.policy
  if policy and policy[field] == false then
    error((action or field) .. ' denied by scope Closure', 3)
  end
end

local function item_kind(item)
  local life = Lifetime.of(item)
  if not life then return nil end
  return life:_task() ~= nil and 'task' or 'resource'
end

local function offer_op(lifetime, role, value)
  local spec = Facility.rule.exchange({ resource = lifetime, role = role })
  return role == 'put' and Facility.bind(spec, value) or Facility.op(spec)
end

local SCOPE_OPTIONS = { parent = true, closure = true, runtime = true, lifetime = true, label = true }

local function ensure_scope_result(lifetime)
  local role = lifetime:_scope_role(true)
  local completion = role.result
  if completion then return completion end
  completion = Completion.new():label('scope-result')
  role.result = completion
  Label.child(completion, lifetime, 'scope-result')
  return completion
end

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
      closure = Closure.running(),
      label = opts.label,
    })
  end
  local role = lifetime:_scope_role(true)
  role.policy = Closure._merge_policy(role.policy, Closure.policy(opts.closure))
  local scope = setmetatable({
    _mask_depth = 0,
    _lifetime = lifetime,
    _role = role,
    _parent_hint = opts.parent,
    _fibers_id = id,
    _fibers_scope = true,
  }, Scope)
  if opts.runtime then scope:_bind_runtime(opts.runtime) end
  return scope
end


function Scope.for_lifetime(lifetime)
  if not Lifetime.is(lifetime) then
    error('Scope.for_lifetime expects a Lifetime', 2)
  end
  next_id = next_id + 1
  return setmetatable({
    _mask_depth = 0,
    _lifetime = lifetime,
    _role = lifetime:_scope_role(true),
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
  parent = parent or (self._parent_hint and self._parent_hint._lifetime or nil)
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
  if parent then
    parent:_bind_runtime(runtime)
    self._lifetime:_bind_runtime(runtime)
  else
    self._lifetime:_bind_runtime(runtime)
    local store = runtime:_lifetime_store()
    if store:_phase(self._lifetime) == 'dormant' then
      store:_bootstrap_admit(runtime:_lifetime_root(), self._lifetime)
    end
  end
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

function Scope:_run_child_body(fn, task)
  if not task or not task._lifetime then
    error('Scope:_run_child_body expects a Task Lifetime', 2)
  end
  -- Task creation fixes the Scope role and policy before admission. Once the
  -- admission commit activates the body, execution needs only another view of
  -- that already-configured Lifetime; no policy is merged a second time.
  local child = Scope.for_lifetime(task._lifetime)
  child:_bind_runtime(self._lifetime._runtime or Runtime.current())
  return ScopeClosure.run(child, function(s)
    return fn(s, task)
  end, child._role.policy, function(results, runtime)
    task:_publish_protected_body_result(results, runtime)
  end):raise()
end

function Scope:_drive_op(value, spec)
  spec = Contract.table(spec, 'driven Lifetime spec', 2)
  if type(spec.run) ~= 'function' then error('driven Lifetime requires spec.run', 2) end
  Lifetime.define(value, {
    label = spec.label, role = assert(spec.role, 'driven Lifetime requires spec.role'),
    closure = assert(spec.closure, 'driven Lifetime requires spec.closure'), children = spec.children,
  })
  for _, state in ipairs(spec.causal_states or {}) do Lifetime._mark_causal_state(value, state) end
  -- A driven resource is an ordinary Scope-backed Task view over the same
  -- Lifetime.  Its computation result must publish when spec.run returns,
  -- before descendant closure and retirement, exactly like Scope:spawn_op.
  -- Wrapping private_scope:run inside a Task-owned body result would make body
  -- completion depend on the Lifetime's own retirement and can deadlock an
  -- ancestor close claim.
  local parent = self
  local driver = Task._new(function(task_handle)
    return parent:_run_child_body(spec.run, task_handle)
  end, self, {
    lifetime = value._lifetime, closure = self._role.policy, label = spec.label,
    execution_kind = 'resource_driver',
  })
  value._driver = driver
  return self:admit_op(value):map(function() return value end)
end

function Scope:spawn_op(fn, opts)
  if type(fn) ~= 'function' then
    error('Scope:spawn_op expects a function', 2)
  end
  opts = Contract.options(opts, { label = true, closure = true }, 'Scope:spawn_op options', 2)
  local parent = self
  local task = Task._new(function(task_handle)
    return parent:_run_child_body(fn, task_handle)
  end, self, {
    label = opts.label,
    closure = opts.closure,
    execution_kind = 'task',
  })
  return self
    :admit_op(task)
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
  local runtime = self:_bind_runtime()
  r:_bind_runtime(runtime)
  return runtime:_lifetime_store():move_op(self, item, r):map(function()
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
  local put_offer = offer_op(target_sc._lifetime, 'put', offer)
  return self:move_op(item, target_sc):and_then(put_offer:map(function()
      return offer
    end))
end

function Scope:accept_op(filter)
  if filter == nil then
    return offer_op(self._lifetime, 'get')
  end
  if type(filter) ~= 'function' then
    error('Scope:accept_op filter must be a function', 2)
  end
  return offer_op(self._lifetime, 'get'):and_then(Op.guard(function(offer)
    if filter(offer) then
      return Op.always(offer)
    end
    -- Rejection rejects this possible world.  It must not consume an unrelated
    -- offer and loop, because the custody transfer itself is part of the same committed
    -- transaction.
    return Op.never()
  end))
end

local function phase_live(snapshot)
  return snapshot ~= nil and snapshot.phase == 'live'
end

local function grant_can_op(scope, item, right)
  local subject_lifetime = Lifetime.require(item, 3)
  return scope:_store():children_op(scope):and_then(Op.guard(function(items)
    local function scan(i)
      if i > #items then
        return Op.never()
      end
      local b = items[i]
      if Grant.is(b) and Grant._subject_lifetime(b) == subject_lifetime and b:has_right(right) then
        return Op.each({
          scope:_store():custody_snapshot_op(scope, b),
          scope:_store():active_op(subject_lifetime),
        }):and_then(Op.guard(function(rows)
          local snapshot = rows[1][1]
          local subject_active = rows[2][1]
          if phase_live(snapshot) and subject_active then
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

function Scope:start_close_op(item, reason)
  return Closure.start_close_op(self, item, reason or 'closed')
end

-- Direct structural closure is intentionally two transactions: start commits
-- the CloseClaim and its emitted driver; result observes the later retirement or
-- retained failure. The `_op` surface exposes those phases separately.
function Scope:close(item, reason)
  local perform = require('fibers.perform')
  local process = perform(self:start_close_op(item, reason))
  local ok, result = perform(process:result_op())
  if not ok then error(result, 0) end
  return result
end

function Scope:_request_cancel_op(reason)
  return self._lifetime:request_cancel_op(reason)
end

function Scope:request_cancel_op(reason)
  -- Bind the Scope while the Option is constructed, as other Scope operations
  -- do. Guard activation happens inside kernel search, where Runtime.current()
  -- is deliberately not an ambient dependency. Binding does not request close
  -- or raise interruption; those remain transactional consequences.
  self:_bind_runtime()
  return ScopeClosure.request_cancel_op(self, reason)
end

function Scope:cancel_requested_op()
  return self._lifetime:cancel_requested_op()
end

function Scope:_running_children_op()
  return self:_store():children_op(self):map(function(children)
    local tasks = {}
    for i = 1, #children do
      local life = Lifetime.of(children[i])
      if life and life:_task() ~= nil then tasks[#tasks + 1] = life end
    end
    return { tasks = tasks, children = children }
  end)
end

function Scope:begin_close_op(reason, opts)
  opts = Contract.options(opts, { cancel_body = true, cancel_children = true }, 'Scope:begin_close_op options', 2)
  Contract.optional_boolean(opts.cancel_body, 'Scope:begin_close_op cancel_body', 2)
  Contract.optional_boolean(opts.cancel_children, 'Scope:begin_close_op cancel_children', 2)
  return self:_running_children_op():and_then(Op.guard(function(snapshot)
    -- Cancellation is a close request with interruption, not a second lifecycle
    -- transition. Choose one close-intent operation for this Lifetime.
    local close_intent = opts.cancel_body ~= false
      and self:_request_cancel_op(reason)
      or self._lifetime:request_close_op(reason)
    local ops = { close_intent, self:seal_op(reason) }
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

function Scope:sealed_op()
  return self:_store():sealed_op(self):map(function() return self end)
end

local function unresolved_closure(result)
  -- Closure failure is orthogonal to the Scope's primary result.  A body or
  -- child failure may remain primary while cleanup also leaves live
  -- responsibility behind.  Any retained closure failure therefore prevents
  -- self-retirement until that responsibility is recovered.
  return ScopeResult.is(result)
    and result.closure_failures
    and #result.closure_failures > 0
end

-- Scope execution completion is separate from terminal Lifetime outcome.  The
-- result is published on the Scope execution view while the Lifetime may still
-- be CLOSING; retirement alone publishes the terminal Lifetime outcome.
function Scope:_settle_done_op(result)
  local completion = ensure_scope_result(self._lifetime)
  local publish = completion:publish_success_op(result):and_then(Op.guard(function(first, conflict)
    if first ~= true then error('Scope result already published: ' .. tostring(conflict), 3) end
    return Op.always(result)
  end))
  if unresolved_closure(result) then
    return publish:and_then(self._lifetime:_record_closure_fault_op(result.primary, result.reason))
      :map(function() return result, self end)
  end
  return publish:map(function() return result, self end)
end

function Scope:_result_completion()
  return ensure_scope_result(self._lifetime)
end

function Scope:_result_op()
  return self:_result_completion():success_op()
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
  local runtime = self:_bind_runtime()
  local parent = self:parent_scope()
  ensure_scope_result(self._lifetime)
  if parent and self:_store():_phase(self._lifetime) == 'dormant' then
    -- A child Scope is itself an owned Lifetime. Synchronous lexical use does
    -- not bypass the same admission law used by Tasks and resources.
    parent:perform(parent:admit_op(self._lifetime))
    self:_bind_runtime(runtime)
  end
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
