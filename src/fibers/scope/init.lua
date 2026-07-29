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
local ScopeReport = require('fibers.scope.report')
local ScopeResult = require('fibers.scope.result')
local Closure = require('fibers.closure')
local ScopeClosure = require('fibers.scope.closure')
local Lifetime = require('fibers.lifetime')

local unpack_ = table.unpack or unpack
local function pack(...)
  return { n = select('#', ...), ... }
end

local Scope = {}
Scope.__index = function(self, key)
  local method = Scope[key]
  if method ~= nil then
    return method
  end
  local life = rawget(self, '_lifetime')
  if not life then
    return nil
  end
  if key == 'name' then
    return life.name
  end
  if key == 'runtime' then
    return life.runtime
  end
  if key == 'closure' then
    return life.closure
  end
  if key == 'offers' then
    return life.offers
  end
  if key == 'interrupt' then
    return life.interrupt
  end
  if key == 'cancellation' then
    return life.cancellation
  end
  return nil
end
Scope.__newindex = function(self, key, value)
  if
    key == 'runtime'
    or key == 'closure'
    or key == 'offers'
    or key == 'interrupt'
    or key == 'cancellation'
    or key == 'parent'
  then
    error('Scope capability fields are read-only views of its Lifetime', 2)
  end
  rawset(self, key, value)
end

local next_id = 0

local function is_scope(x)
  return type(x) == 'table' and x._fibers_scope == true
end

local function target_scope(target)
  return is_scope(target) and target or nil
end

local function closure_allows(scope, method, flag, ...)
  local closure = scope.closure
  if not closure then
    return true
  end
  local f = closure[method]
  if type(f) == 'function' then
    local ok, reason = f(closure, scope, ...)
    if ok == false then
      return false, reason
    end
    return true
  end
  if flag and closure[flag] == false then
    return false, method .. ' denied by scope Closure'
  end
  return true
end

local function require_closure(scope, method, flag, ...)
  local ok, reason = closure_allows(scope, method, flag, ...)
  if not ok then
    error(reason or (method .. ' denied by scope Closure'), 3)
  end
end

local function item_kind(item)
  local life = Lifetime.of(item)
  if not life then
    return nil
  end
  return life.has_body and 'task' or 'resource'
end

local function new_offers(name)
  return Rendezvous.new(name)
end

function Scope.new(name, opts)
  opts = opts or {}
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
    lifetime = Lifetime.new(name or id, {
      parent = opts.parent and opts.parent._lifetime or nil,
      closure = opts.closure,
      cancellation = opts.cancellation,
      interrupt = opts.interrupt,
      outcome = opts.done,
      standalone_boundary = true,
    })
  end
  if opts.runtime then
    lifetime:bind_runtime(opts.runtime)
  end
  lifetime.closure = Closure.combine(lifetime.closure, opts.closure)
  lifetime.offers = lifetime.offers or opts.offers or new_offers((name or id) .. '-offers')
  return setmetatable({
    mask_depth = opts.mask_depth or 0,
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
    mask_depth = 0,
    _lifetime = lifetime,
    _fibers_id = 'scope-view-' .. tostring(next_id),
    _fibers_scope = true,
  }, Scope)
end

function Scope:parent_scope()
  local lifetime = self._lifetime
  local parent
  if lifetime.runtime and lifetime.runtime.lifetimes then
    parent = lifetime.runtime.lifetimes:current_custodian(lifetime)
  end
  parent = parent or lifetime:_construction_parent_node()
  if not parent or parent == lifetime then
    return nil
  end
  return Scope.for_lifetime(parent)
end

function Scope:lifetime()
  return self._lifetime
end

function Scope:_bind_runtime(runtime)
  runtime = runtime or self._lifetime.runtime or Runtime.current()
  if not runtime then
    error('Scope requires a current Runtime', 2)
  end
  local parent = self:parent_scope()
  if parent then
    parent:_bind_runtime(runtime)
  end
  self._lifetime:bind_runtime(runtime)
  return runtime
end

function Scope:_store()
  return self:_bind_runtime().lifetimes
end

function Scope:admit_op(value)
  require_closure(self, 'allow_admit', 'permit_admission', value)
  local node = Lifetime.of(value)
  if not node then
    error('Scope:admit_op expects a value carrying a dormant Lifetime', 2)
  end
  local runtime = self:_bind_runtime()
  node:assert_runtime_compatible(runtime)
  return runtime.lifetimes:admit_op(self, node):map(function()
    return value
  end)
end

function Scope:perform(op)
  local rt = self.runtime or Runtime.current()
  if not rt then
    error('Scope:perform requires a current runtime or scope runtime', 2)
  end
  local token
  if (self.mask_depth or 0) <= 0 then
    token = self.interrupt
  end
  return rt:_perform_current(op, token, false)
end

function Scope:mask(fn, ...)
  if type(fn) ~= 'function' then
    error('Scope:mask expects a function', 2)
  end
  self.mask_depth = (self.mask_depth or 0) + 1
  local r = pack(Protected.pcall(fn, ...))
  self.mask_depth = self.mask_depth - 1
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
  local child = Scope.new(opts.name or task.name or 'child', {
    parent = self,
    closure = opts.closure or self.closure,
    runtime = self.runtime or Runtime.current(),
    lifetime = task._lifetime,
  })
  return child:run(function(s)
    return fn(s, task)
  end)
end

function Scope:spawn_op(fn, opts)
  if type(fn) ~= 'function' then
    error('Scope:spawn_op expects a function', 2)
  end
  opts = type(opts) == 'string' and { name = opts } or (opts or {})
  local parent = self
  local task = Task._new(
    function(task_handle)
      return parent:_run_child_body(fn, task_handle, opts)
    end,
    opts.name,
    self,
    {
      closure = Closure.running(opts.closure or self.closure),
    }
  )
  return self
    :admit_op(task)
    :and_then(function()
      return task:spawn_effect_op()
    end, false)
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
  require_closure(self, 'allow_move', 'permit_outward_move', item, target)
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
    type = 'custody_transfer',
    from = self,
    from_scope = self,
    to = target_sc,
    to_scope = target_sc,
    item = item,
    task = item,
    item_kind = item_kind(item),
    terms = terms,
    name = item and item.name or nil,
  }
  local put_offer = target_sc.offers:put_op(offer)
  return self:move_op(item, target_sc):and_then(function()
    return put_offer:map(function()
      return offer
    end)
  end, Op.dependencies(put_offer))
end

function Scope:accept_op(filter)
  if filter == nil then
    return self.offers:get_op()
  end
  if type(filter) ~= 'function' then
    error('Scope:accept_op filter must be a function', 2)
  end
  return self.offers:get_op():and_then(function(offer)
    if filter(offer) then
      return Op.always(offer)
    end
    -- Rejection rejects this possible world.  It must not consume an unrelated
    -- offer and loop, because the custody transfer itself is part of the same committed
    -- transaction.
    return Op.never()
  end, false)
end

local function phase_live(record)
  return record ~= nil and record.phase == 'live'
end

local function grant_can_op(scope, item, right)
  local subject_lifetime = Lifetime.require(item, 3)
  return scope:_store():roots_op(scope):and_then(function(items)
    local function scan(i)
      if i > #items then
        return Op.never()
      end
      local b = items[i]
      if Grant.is(b) and Grant._subject_lifetime(b) == subject_lifetime and b:has_right(right) then
        return Op.all({
          scope:_store():record_op(scope, b),
          scope:_store():active_op(subject_lifetime),
        }):and_then(function(rows)
          local record = rows[1][1]
          local subject_active = rows[2][1]
          if phase_live(record) and subject_active then
            return Op.always(item, { kind = 'grant', grant = b, right = right })
          end
          return scan(i + 1)
        end)
      end
      return scan(i + 1)
    end
    return scan(1)
  end)
end

function Scope:can_op(item, right)
  right = right or 'use'
  return self
    :_store()
    :custody_can_op(self, item, right, { allow_closing = (self._closure_depth or 0) > 0 })
    :and_then(function(ok, phase)
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
    end)
end

local function parse_grant_args(self, a, b, c)
  local holder, rights, opts
  if is_scope(a) then
    holder, rights, opts = a, b, c or {}
  else
    rights, opts = a, b or {}
    holder = opts.holder or opts.scope or self
  end
  if not is_scope(holder) then
    error('Scope:grant_op expects a holder Scope', 3)
  end
  return holder, rights, opts or {}
end

function Scope:grant_op(item, holder_or_rights, rights_or_opts, maybe_opts)
  local holder, rights, opts = parse_grant_args(self, holder_or_rights, rights_or_opts, maybe_opts)
  local runtime = self:_bind_runtime()
  holder:_bind_runtime(runtime)
  if holder.runtime ~= runtime then
    error('Scope:grant_op requires both Scopes to belong to the same Runtime', 2)
  end
  local grant = Grant._new(self, holder, item, rights, {
    name = opts.name,
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
    ops[#ops + 1] = self:_store():custody_can_op(self, item, right):and_then(function(ok)
      return ok and Op.always(true) or Op.never()
    end)
  end
  return Op.all(ops)
    :and_then(function()
      return holder:admit_op(grant)
    end)
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

function Scope:cancellation_op()
  return self._lifetime:cancellation_op()
end

function Scope:running_children_op()
  local roots_op = self:_store():roots_op(self)
  return self:_store():status_op(self):and_then(function(status)
    return roots_op:map(function(roots)
      local tasks = {}
      for i = 1, #roots do
        local item = roots[i]
        local life = Lifetime.of(item)
        if life and life.has_body then
          tasks[#tasks + 1] = life
        end
      end
      return { version = status.version, tasks = tasks, roots = roots }
    end)
  end, Op.dependencies(roots_op))
end

function Scope:begin_close_op(reason, opts)
  opts = opts or {}
  return self:running_children_op():and_then(function(snapshot)
    local ops = { self._lifetime:request_close_op(reason), self:seal_op(reason) }
    if opts.cancel_body ~= false then
      ops[#ops + 1] = self:_request_cancel_op(reason)
    end
    if opts.cancel_children ~= false then
      for i = 1, #snapshot.tasks do
        ops[#ops + 1] = snapshot.tasks[i]:request_cancel_op(reason)
      end
    end
    return Op.all(ops):map(function()
      return snapshot
    end)
  end)
end

function Scope:seal_op(_reason)
  return self:_store():seal_op(self):or_else(Op.always(true)):map(function()
    return self
  end)
end

local function lifetime_sealed_op(scope)
  return scope:_store():status_op(scope):and_then(function(status)
    if status.sealed then
      return Op.always(true)
    end
    return scope:_store():changed_op(scope, status.version):and_then(function()
      return lifetime_sealed_op(scope)
    end)
  end)
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
  return Op.all({ phase_op, lifetime:publish_outcome_op(result) }):map(function()
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
function Scope:children_op()
  return self:_store():roots_op(self)
end
function Scope:custody_op(item)
  return self:_store():record_op(self, item)
end
function Scope:subtree_op(item)
  return self:_store():subtree_op(self, item)
end

function Scope:inspect_op()
  local outcome_read = self._lifetime.outcome:read_op()
  local node_state = self:_store():node_state_op(self._lifetime)
  return self:_store():status_op(self):and_then(function(lifetime_status)
    return node_state:and_then(function(state)
      return outcome_read:map(function(outcome_state)
        local done = type(outcome_state) == 'table' and outcome_state.status == 'done'
        local result = done and outcome_state.result or nil
        return {
          name = self.name,
          phase = state.closure_phase,
          close_reason = state.closure_reason,
          close_error = state.closure_error,
          open = lifetime_status.open == true,
          sealed = lifetime_status.sealed == true,
          done = done,
          outcome = done and (ScopeResult.is(result) and result:done_outcome() or result) or nil,
          result = result,
          cancelled = self.interrupt and self.interrupt.raised or false,
          cancel_reason = self.interrupt and self.interrupt.reason or nil,
          custody_count = lifetime_status.custody_count,
          root_count = lifetime_status.root_count,
          lifetime_version = lifetime_status.version,
          lifetime = self._lifetime,
          scope = self,
        }
      end)
    end, Op.dependencies(outcome_read))
  end, Op.dependencies(node_state, outcome_read))
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
Scope.is_scope = is_scope
function Scope.is_report(x)
  return ScopeReport.is(x)
end
return Scope
