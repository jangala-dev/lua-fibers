-- Scope: lightweight lifetime boundary and custody calculus.
--
-- A Scope is not a kernel primitive.  Region is the ownership ledger; Scope
-- provides ordinary execution, custody/authority commands, two boundary facts
-- (sealed and done), and diagnostic inspection.

local Op = require('fibers.atoms.op')
local Region = require('fibers.atoms.region')
local Rendezvous = require('fibers.atoms.rendezvous')
local Scalar = require('fibers.atoms.scalar')
local EventQueue = require('fibers.atoms.event_queue')
local Task = require('fibers.task')
local Lease = require('fibers.atoms.lease')
local Borrow = require('fibers.borrow')
local Runtime = require('fibers.kernel.runtime')
local Protected = require('fibers.internal.protected')
local ScopeReport = require('fibers.scope.report')
local ScopeResult = require('fibers.scope.result')
local Interrupt = require('fibers.internal.interrupt')
local Settlement = require('fibers.internal.settlement')
local ScopePolicy = require('fibers.scope.policy')

local unpack_ = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end

local Scope = {}
Scope.__index = Scope

local RequestCancellation = Scalar.transition {
  name = 'scope.request_cancel',
  mode = 'update',
  step = function(state, payload)
    if type(state) == 'table' and (state.requested or state.cancelled) then
      return Scalar.Ready.same(false, state.reason)
    end
    local next_state = { requested = true, cancelled = true, reason = payload.reason }
    return Scalar.Ready.write(next_state, true, payload.reason)
  end,
}

local next_id = 0

local function is_region(x)
  return type(x) == 'table' and x._fibers_kind == Region.Kind
end

local function is_scope(x)
  return type(x) == 'table' and x._fibers_scope == true
end

local function target_region(target)
  if is_scope(target) then return target.region end
  if is_region(target) then return target end
  return nil
end

local function target_scope(target)
  return is_scope(target) and target or nil
end

local function policy_allows(scope, method, flag, ...)
  local policy = scope.policy
  if not policy then return true end
  local f = policy[method]
  if type(f) == 'function' then
    local ok, reason = f(policy, scope, ...)
    if ok == false then return false, reason end
    return true
  end
  if flag and policy[flag] == false then return false, method .. ' denied by scope policy' end
  return true
end

local function require_policy(scope, method, flag, ...)
  local ok, reason = policy_allows(scope, method, flag, ...)
  if not ok then error(reason or (method .. ' denied by scope policy'), 3) end
end

local function item_kind(item)
  return item and (item._fibers_obligation_kind or item._fibers_kind_name or item._fibers_id and 'owned' or nil)
end

local function new_offers(name)
  return Rendezvous.new(name)
end

local function wait_state(scalar, pred)
  local dependencies = Op.dependencies(scalar:snapshot_op(), scalar:changed_op(0))
  local function loop()
    return scalar:snapshot_op():and_then(function(s)
      if pred(s.value) then return Op.always(s.value) end
      return scalar:changed_op(s.version):and_then(function() return loop() end, dependencies)
    end, dependencies)
  end
  return loop()
end

function Scope.new(name, opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'scope-' .. tostring(next_id)
  local region = opts.region or Region.new(name or id)
  if not is_region(region) then error('Scope.new expects opts.region to be a Region', 2) end
  if opts.parent ~= nil and not is_scope(opts.parent) then error('Scope.new expects opts.parent to be a Scope', 2) end
  local scope = setmetatable({
    name = name or region.name or id,
    parent = opts.parent,
    policy = opts.policy,
    runtime = opts.runtime,
    region = region,
    sealed = opts.sealed or Scalar.new(false, (name or id) .. '-sealed'),
    done = opts.done or Scalar.new({ status = 'pending' }, (name or id) .. '-done'),
    cancellation = opts.cancellation or Scalar.new({ requested = false, cancelled = false }, (name or id) .. '-cancellation'),
    offers = opts.offers or new_offers((name or id) .. '-offers'),
    _lifetime_events = opts.lifetime_events or EventQueue.new((name or id) .. '-lifetime-events'),
    authority_leases = opts.authority_leases or Lease.new(opts.authority_compat or {
      read = { read = true, observe = true },
      observe = { read = true, observe = true },
      borrow = { read = true, observe = true, borrow = true },
      use = { use = true },
      write = {},
    }, (name or id) .. '-authority'),
    interrupt = opts.interrupt or Interrupt.new((name or id) .. '-interrupt'),
    mask_depth = opts.mask_depth or 0,
    _fibers_id = id,
    _fibers_scope = true,
  }, Scope)
  if region._fibers_scope_owner == nil then region._fibers_scope_owner = scope end
  return scope
end

function Scope:raw_region()
  return self.region
end


function Scope:admit_op(item_or_owned, from_owner)
  require_policy(self, 'allow_admit', 'permit_admission', item_or_owned, from_owner)
  return self.region:admit_op(item_or_owned, from_owner)
end


function Scope:perform(op)
  local rt = self.runtime or Runtime.current()
  if not rt then error('Scope:perform requires a current runtime or scope runtime', 2) end
  local token
  if (self.mask_depth or 0) <= 0 then token = self.interrupt end
  return rt:perform(op, { interrupt = token })
end

function Scope:mask(fn, ...)
  if type(fn) ~= 'function' then error('Scope:mask expects a function', 2) end
  self.mask_depth = (self.mask_depth or 0) + 1
  local r = pack(Protected.pcall(fn, ...))
  self.mask_depth = self.mask_depth - 1
  if not r[1] then error(r[2], 0) end
  return unpack_(r, 2, r.n)
end

function Scope:_run_child_body(fn, task, opts)
  opts = opts or {}
  local child = Scope.new(opts.name or (task and task.name) or 'child', {
    parent = self,
    policy = opts.policy or self.policy,
    runtime = self.runtime or Runtime.current(),
    interrupt = task and task.interrupt or nil,
    cancellation = task and task.cancellation or nil,
  })
  return child:run(function(s)
    return fn(s, task)
  end)
end

function Scope:spawn_op(fn, opts)
  if type(fn) ~= 'function' then error('Scope:spawn_op expects a function', 2) end
  opts = type(opts) == 'string' and { name = opts } or (opts or {})
  local parent = self
  local task = Task.new(function(task_handle)
    return parent:_run_child_body(fn, task_handle, opts)
  end, opts.name, self)
  local owned = task:owned(opts.settle or Settlement.task_join_only(), {
    role = 'task',
    settle_name = opts.settle_name or 'task_join_only',
  })
  return self:admit_op(owned):and_then(function()
    return task:spawn_effect_op()
  end, false):map(function() return task end)
end

function Scope:spawn(fn, opts)
  return self:perform(self:spawn_op(fn, opts))
end

function Scope:move_op(item, target)
  local r = target_region(target)
  if not r then error('Scope:move_op expects a target Scope or Region', 2) end
  require_policy(self, 'allow_move', 'permit_outward_move', item, target)
  return self.region:move_op(item, r):map(function() return item end)
end

function Scope:offer_op(item, target, terms)
  local target_sc = target_scope(target)
  if not target_sc then error('Scope:offer_op expects a target Scope', 2) end
  local offer = {
    type = 'custody_offer',
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
    return put_offer:map(function() return offer end)
  end, Op.dependencies(put_offer))
end

function Scope:accept_op(filter)
  if filter == nil then return self.offers:get_op() end
  if type(filter) ~= 'function' then error('Scope:accept_op filter must be a function', 2) end
  return self.offers:get_op():and_then(function(offer)
    if filter(offer) then return Op.always(offer) end
    -- Rejection rejects this possible world.  It must not consume an unrelated
    -- offer and loop, because the custody offer itself is part of the same committed
    -- transaction.
    return Op.never()
  end, false)
end


local function phase_live(record)
  return record ~= nil and record.phase == 'live'
end

local function borrow_authorise_op(scope, item, right)
  return scope.region:members_op():and_then(function(items)
    local function scan(i)
      if i > #items then return Op.never() end
      local b = items[i]
      if Borrow.is(b) and b.subject == item and b:has_right(right) then
        return scope.region:record_op(b):and_then(function(record)
          if phase_live(record) then return Op.always(item, { kind = 'borrow', borrow = b, right = right }) end
          return scan(i + 1)
        end)
      end
      return scan(i + 1)
    end
    return scan(1)
  end)
end

local function inherited_owner_scope(scope, item)
  local owner = item and item.owner
  local owner_scope = owner and owner._fibers_scope_owner
  if not owner_scope or owner_scope == scope then return nil end
  local p = scope.parent
  while p do
    if p == owner_scope then return owner_scope end
    p = p.parent
  end
  return nil
end

function Scope:authorise_op(item, right)
  local owner_scope = inherited_owner_scope(self, item)
  if owner_scope then return owner_scope:authorise_op(item, right) end
  return self.region:authorise_op(item, right, { allow_claimed = (self._settlement_depth or 0) > 0 }):and_then(function(ok, phase)
    if ok then
      local kind = phase == 'claimed' and 'settlement' or 'owned'
      return Op.always(item, { kind = kind, scope = self, right = right })
    end
    local borrowed = borrow_authorise_op(self, item, right)
    if self.parent then
      -- Child scopes inherit authority to use live obligations owned by their
      -- ancestors.  Custody does not move; ordinary use is delegated down the
      -- dynamic scope tree unless a membrane or borrow discipline later narrows it.
      borrowed = borrowed:or_else(self.parent:authorise_op(item, right))
    end
    return borrowed
  end)
end

local function parse_borrow_args(self, a, b, c)
  local borrower, rights, opts
  if is_scope(a) then
    borrower, rights, opts = a, b, c or {}
  else
    rights, opts = a, b or {}
    borrower = opts.borrower or opts.scope or self
  end
  if not is_scope(borrower) then error('Scope:borrow_op expects a borrower Scope', 3) end
  return borrower, rights, opts or {}
end

function Scope:borrow_op(item, borrower_or_rights, rights_or_opts, maybe_opts)
  local borrower, rights, opts = parse_borrow_args(self, borrower_or_rights, rights_or_opts, maybe_opts)
  local borrow = Borrow.new(self, borrower, item, rights, {
    lease = opts.lease or self.authority_leases,
    name = opts.name,
    meta = opts.meta,
  })
  local ops = { self:authorise_op(item, opts.grant_right or 'borrow') }
  for i = 1, #(borrow.right_list or {}) do
    local mode = borrow.right_list[i]
    ops[#ops + 1] = borrow.lease:acquire_op(item, mode, borrow._fibers_id .. ':' .. tostring(mode))
  end
  return Op.all(ops):and_then(function()
    return borrower:admit_op(Region.Owned.item(borrow, borrow._fibers_settle, {
      role = 'borrow',
      settle_name = 'borrow',
      meta = { subject = item, grantor = self, rights = borrow.rights },
    }))
  end):map(function() return borrow end)
end

function Scope:claim_op(item, purpose)
  return self.region:claim_op(item, purpose)
end

function Scope:resolve_op(claim, resolution)
  if resolution == nil then error('Scope:resolve_op requires a resolution', 2) end
  return self.region:resolve_claim_op(claim, resolution)
end


function Scope:request_cancel_op(reason)
  return self.cancellation:transition_op(RequestCancellation, { reason = reason }):and_then(function(first, recorded_reason)
    if not first then return Op.always(false, recorded_reason) end
    return Op.emit(require('fibers.atoms.effect').interrupt(self.interrupt, recorded_reason)):map(function()
      return true, recorded_reason
    end)
  end, false)
end

function Scope:cancel_requested_op()
  return wait_state(self.cancellation, function(v)
    return type(v) == 'table' and (v.requested == true or v.cancelled == true)
  end):map(function(v)
    return true, v.reason
  end)
end

function Scope:cancellation_op()
  return self.cancellation:read_op()
end

function Scope:task_roots_snapshot_op()
  local roots_op = self.region:roots_op()
  return self.region:snapshot_op():and_then(function(status)
    return roots_op:map(function(roots)
      local tasks = {}
      for i = 1, #roots do
        local item = roots[i]
        if type(item) == 'table' and item._fibers_obligation_kind == 'task' then
          tasks[#tasks + 1] = item
        end
      end
      return { version = status.version, tasks = tasks, roots = roots }
    end)
  end, Op.dependencies(roots_op))
end

function Scope:begin_close_op(reason, opts)
  opts = opts or {}
  return self:task_roots_snapshot_op():and_then(function(snapshot)
    local ops = { self:seal_op(reason) }
    if opts.cancel_body ~= false then ops[#ops + 1] = self:request_cancel_op(reason) end
    if opts.cancel_children ~= false then
      for i = 1, #snapshot.tasks do
        ops[#ops + 1] = snapshot.tasks[i]:request_cancel_op(reason)
      end
    end
    return Op.all(ops):map(function() return snapshot end)
  end)
end

function Scope:seal_op(_reason)
  local write_sealed = self.sealed:write_op(true)
  return self.region:seal_op():or_else(Op.always(true)):and_then(function()
    return write_sealed
  end, Op.dependencies(write_sealed))
end

function Scope:sealed_op()
  return wait_state(self.sealed, function(v) return v == true end):map(function() return self end)
end

function Scope:_mark_done_op(result)
  local outcome = ScopeResult.is(result) and result:done_outcome() or result
  return self.done:write_op({ status = 'done', outcome = outcome }):map(function() return outcome end)
end

function Scope:done_op()
  return wait_state(self.done, function(v) return type(v) == 'table' and v.status == 'done' end):map(function(v) return v.outcome end)
end

function Scope:owns_op(item) return self.region:owns_op(item) end
function Scope:roots_op() return self.region:roots_op() end
function Scope:record_op(item) return self.region:record_op(item) end
function Scope:subtree_op(item) return self.region:subtree_op(item) end


function Scope:inspect_op()
  local sealed_read, done_read = self.sealed:read_op(), self.done:read_op()
  return self.region:snapshot_op():and_then(function(region_status)
    return sealed_read:and_then(function(sealed)
      return done_read:map(function(done)
        local done_status = type(done) == 'table' and done.status == 'done'
        return {
          open = region_status.open,
          sealed = sealed == true or region_status.sealed == true,
          done = done_status,
          outcome = done_status and done.outcome or nil,
          owned_count = region_status.owned_count,
          root_count = region_status.root_count,
          claimed_count = region_status.claimed_count,
          failed_count = region_status.failed_count,
          settlement_failed_count = region_status.settlement_failed_count,
          region_version = region_status.version,
          region = self.region,
          scope = self,
        }
      end)
    end, Op.dependencies(done_read))
  end, Op.dependencies(sealed_read, done_read))
end


function Scope:_make_report(primary, secondaries, fields)
  return ScopeReport.new(self, primary, secondaries, fields)
end

function Scope:try_run(fn)
  return ScopePolicy.try_run(self, fn)
end

function Scope:run(fn)
  return self:try_run(fn):raise()
end

Scope.Region = Region
Scope.Report = ScopeReport
Scope.is_scope = is_scope
function Scope.is_report(x) return ScopeReport.is(x) end
return Scope
