package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local FibersRuntime = require('fibers.runtime')
local Grant = require('fibers.grant')
local Lifetime = require('fibers.lifetime')
local Lifetimes = require('tests.support.lifetimes')
local FibersScope = require('fibers.scope')
local FibersFlow = require('fibers.resource.flow')
local Closure = require('fibers.closure')
local Completion = require('fibers.resource.completion')

local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end

local function maybe(op)
  return op:map(function()
    return 'yes'
  end):or_else(Op.always('no'))
end

-- Direct custody grants authority while the Lifetime is live. Closing the
-- Lifetime resolves custody and removes that authority.
do
  local owner
  local h = Lifetimes.resource('authority-owned')
  local live_auth, closed_auth
  fibers.run(function()
    owner = FibersScope.new('authority-owner', { runtime = FibersRuntime.current() })
    fibers.perform(owner:admit_op(h))
    live_auth = fibers.perform(maybe(owner:can_op(h, 'write')))
    fibers.perform(owner:close_op(h, 'done'))
    closed_auth = fibers.perform(maybe(owner:can_op(h, 'write')))
  end)
  assert_eq(live_auth, 'yes', 'live custody should authorise use')
  assert_eq(closed_auth, 'no', 'closed custody should no longer authorise use')
end

-- A Grant supplies selected authority without moving custody. The Grant is an
-- ordinary child Lifetime of its holder, and closing it revokes the authority.
do
  local owner, holder
  local h = Lifetimes.resource('grant-subject')
  local grant, subject_owner, grant_owner, read_auth, write_auth, after_revoke
  fibers.run(function()
    local rt = FibersRuntime.current()
    owner = FibersScope.new('grant-owner', { runtime = rt })
    holder = FibersScope.new('grant-holder', { runtime = rt })
    fibers.perform(owner:admit_op(h))
    grant = fibers.perform(owner:grant_op(h, holder, { 'read' }))
    subject_owner = Lifetime.of(h):current_state().custodian
    grant_owner = Lifetime.of(grant):current_state().custodian
    read_auth = fibers.perform(maybe(holder:can_op(h, 'read')))
    write_auth = fibers.perform(maybe(holder:can_op(h, 'write')))
    fibers.perform(holder:close_op(grant, 'revoked'))
    assert_eq(grant:closed(), grant, 'Grant:closed should return the closed Grant')
    after_revoke = fibers.perform(maybe(holder:can_op(h, 'read')))
    fibers.perform(owner:close_op(h, 'done'))
  end)
  assert_truthy(Grant.is(grant), 'grant_op should return a Grant Lifetime')
  assert_eq(subject_owner, owner:lifetime(), 'a Grant must not move subject custody')
  assert_eq(grant_owner, holder:lifetime(), 'the holder should have custody of the Grant')
  assert_eq(read_auth, 'yes', 'the holder should receive the granted authority')
  assert_eq(write_auth, 'no', 'the holder should not receive ungranted authority')
  assert_eq(after_revoke, 'no', 'closing the Grant should revoke its authority')
end

-- Grants are permissions rather than locks. Independent Grants may coexist;
-- exclusivity, when required, belongs to the subject facility or another Op.
do
  local h = Lifetimes.resource('grant-compat-subject')
  local read_write
  fibers.run(function(scope)
    fibers.perform(scope:admit_op(h))
    local grants = fibers.perform(Op.all({
      scope:grant_op(h, scope, { 'read' }),
      scope:grant_op(h, scope, { 'write' }),
    }):or_else(Op.always(false)))
    read_write = grants and 'yes' or 'no'
  end)
  assert_eq(read_write, 'yes', 'independent permission Grants should commit together')
end

-- Flow endpoints are domain capabilities. A Grant supplies read authority
-- without moving the endpoint Lifetime.
do
  local flow = FibersFlow.new(8, 'flow-authority')
  local direct_auth, granted_auth, granted_byte, granted_err, write_err
  fibers.run(function(owner)
    local holder = FibersScope.new('flow-grant-holder', { runtime = FibersRuntime.current() })
    fibers.perform(Op.all({ owner:admit_op(flow:inlet()), owner:admit_op(flow:outlet()) }))
    local _n, err = fibers.perform(flow:inlet():write_op('ab'))
    write_err = err
    direct_auth = fibers.perform(maybe(holder:can_op(flow:outlet(), 'read')))
    local grant = fibers.perform(owner:grant_op(flow:outlet(), holder, { 'read' }))
    granted_auth = fibers.perform(maybe(holder:can_op(flow:outlet(), 'read')))
    granted_byte, granted_err = fibers.perform(flow:outlet():read_some_op(1))
    fibers.perform(holder:close_op(grant, 'done'))
  end)
  assert_eq(write_err, nil, 'the custodian should write through the inlet held in custody')
  assert_eq(direct_auth, 'no', 'the holder should lack authority before the Grant')
  assert_eq(granted_auth, 'yes', 'the Grant should be visible to can_op')
  assert_eq(granted_byte, 'a', 'the granted reader should read the first byte')
  assert_eq(granted_err, nil, 'the granted read should not fail')
end

-- Closing the subject invalidates every Grant over it, even when the Grant
-- remains a live child of its holder.
do
  local h = Lifetimes.resource('closed-grant-subject')
  local before_close, after_close
  fibers.run(function(owner)
    local holder = FibersScope.new('closed-subject-holder', { runtime = FibersRuntime.current() })
    fibers.perform(owner:admit_op(h))
    local grant = fibers.perform(owner:grant_op(h, holder, { 'read' }))
    before_close = fibers.perform(maybe(holder:can_op(h, 'read')))
    fibers.perform(owner:close_op(h, 'subject closed'))
    after_close = fibers.perform(maybe(holder:can_op(h, 'read')))
    fibers.perform(holder:close_op(grant, 'cleanup'))
  end)
  assert_eq(before_close, 'yes', 'a live subject should honour its Grant')
  assert_eq(after_close, 'no', 'a closed subject should not be authorised by a stale Grant')
end

-- Grants are non-transferable by default. Transferability is an explicit term.
do
  local h = Lifetimes.resource('grant-transfer-subject')
  local default_rejected, explicit_moved
  fibers.run(function(owner)
    local first = FibersScope.new('grant-transfer-first', { runtime = FibersRuntime.current() })
    local second = FibersScope.new('grant-transfer-second', { runtime = FibersRuntime.current() })
    fibers.perform(owner:admit_op(h))
    local fixed = fibers.perform(owner:grant_op(h, first, { 'read' }))
    default_rejected = not pcall(function()
      first:move_op(fixed, second)
    end)
    fibers.perform(first:close_op(fixed, 'cleanup'))

    local movable = fibers.perform(owner:grant_op(h, first, { 'read' }, {
      terms = { transferable = true },
    }))
    fibers.perform(first:move_op(movable, second))
    explicit_moved = Lifetime.of(movable):current_state().custodian == second:lifetime()
    fibers.perform(second:close_op(movable, 'cleanup'))
    fibers.perform(owner:close_op(h, 'done'))
  end)
  assert_eq(default_rejected, true, 'a Grant should be non-transferable unless its terms permit movement')
  assert_eq(explicit_moved, true, 'an explicitly transferable Grant should move atomically')
end

-- Authority flows from a Grant holder to that holder's descendants, never back
-- from a child holder to its parent or sideways to a sibling.
do
  local h = Lifetimes.resource('grant-direction-subject')
  local parent_auth, child_auth, sibling_auth
  fibers.run(function(owner)
    local parent = FibersScope.new('grant-direction-parent', { runtime = FibersRuntime.current() })
    local sibling = FibersScope.new('grant-direction-sibling', { runtime = FibersRuntime.current() })
    local ready = Completion.new('grant-direction-ready')
    fibers.perform(owner:admit_op(h))
    local child_task = fibers.perform(parent:spawn_op(function(child)
      fibers.perform(owner:grant_op(h, child, { 'read' }))
      child_auth = fibers.perform(maybe(child:can_op(h, 'read')))
      fibers.perform(ready:publish_success_op(true))
      fibers.perform(Op.never())
    end))
    fibers.perform(ready:success_op())
    parent_auth = fibers.perform(maybe(parent:can_op(h, 'read')))
    sibling_auth = fibers.perform(maybe(sibling:can_op(h, 'read')))
    fibers.perform(child_task:request_cancel_op('direction test complete'))
  end)
  assert_eq(child_auth, 'yes', 'a holder should receive its Grant authority')
  assert_eq(parent_auth, 'no', 'a parent must not inherit authority granted to a child')
  assert_eq(sibling_auth, 'no', "a sibling must not inherit another holder's Grant")
end

-- Grant rights are explicit and deterministic; sparse or duplicate arrays are
-- rejected at construction rather than interpreted through Lua length rules.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new('grant-validation-owner', { runtime = rt })
  local holder = FibersScope.new('grant-validation-holder', { runtime = rt })
  local h = Lifetimes.resource('grant-validation-subject')
  local sparse = pcall(function()
    owner:grant_op(h, holder, { [1] = 'read', [3] = 'write' })
  end)
  local duplicate = pcall(function()
    owner:grant_op(h, holder, { 'read', 'read' })
  end)
  assert_eq(sparse, false, 'sparse Grant rights should be rejected')
  assert_eq(duplicate, false, 'duplicate Grant rights should be rejected')
end

-- Grant authority and transfer terms are captured at construction. Public Lua
-- fields and inspection snapshots cannot be used to escalate authority.
do
  local h = Lifetimes.resource('grant-immutable-subject')
  local write_auth, moved, inspected_write
  fibers.run(function(owner)
    local holder = FibersScope.new('grant-immutable-holder', { runtime = FibersRuntime.current() })
    local destination = FibersScope.new('grant-immutable-destination', { runtime = FibersRuntime.current() })
    fibers.perform(owner:admit_op(h))
    local grant = fibers.perform(owner:grant_op(h, holder, { 'read' }))

    -- These fields are not authoritative, even if hostile code creates them.
    grant.rights = { write = true }
    grant.terms = { transferable = true }
    grant.subject_lifetime = Lifetime.of({})

    local inspected = grant:inspect()
    inspected.rights.write = true
    inspected.terms.transferable = true
    inspected_write = grant:inspect().rights.write == true

    write_auth = fibers.perform(maybe(holder:can_op(h, 'write')))
    moved = pcall(function()
      holder:move_op(grant, destination)
    end)
    fibers.perform(holder:close_op(grant, 'cleanup'))
    fibers.perform(owner:close_op(h, 'done'))
  end)
  assert_eq(write_auth, 'no', 'mutating a Grant view must not add authority')
  assert_eq(moved, false, 'mutating a Grant view must not enable transfer')
  assert_eq(inspected_write, false, 'mutating an inspection snapshot must not alter the Grant')
end

-- Granted authority may be exercised by a holder but cannot be copied onwards.
-- Version 1 permits Grant issuance only by the subject's current custodian.
do
  local h = Lifetimes.resource('grant-no-subdelegation-subject')
  local delegated
  fibers.run(function(owner)
    local holder = FibersScope.new('grant-no-subdelegation-holder', { runtime = FibersRuntime.current() })
    local leaf = FibersScope.new('grant-no-subdelegation-leaf', { runtime = FibersRuntime.current() })
    fibers.perform(owner:admit_op(h))
    local upstream = fibers.perform(owner:grant_op(h, holder, { 'read' }))
    delegated = fibers.perform(holder
      :grant_op(h, leaf, { 'read' })
      :map(function()
        return true
      end)
      :or_else(Op.always(false)))
    fibers.perform(holder:close_op(upstream, 'cleanup'))
    fibers.perform(owner:close_op(h, 'done'))
  end)
  assert_eq(delegated, false, 'non-custodial Grant authority must not be sub-granted')
end

-- Grant option and term errors are reported at construction.
do
  local rt = FibersRuntime.new()
  local owner = FibersScope.new('grant-term-owner', { runtime = rt })
  local holder = FibersScope.new('grant-term-holder', { runtime = rt })
  local h = Lifetimes.resource('grant-term-subject')
  assert_eq(
    pcall(function()
      owner:grant_op(h, holder, 'read', { terms = 'bad' })
    end),
    false
  )
  assert_eq(
    pcall(function()
      owner:grant_op(h, holder, 'read', { terms = { transferable = 'yes' } })
    end),
    false
  )
  assert_eq(
    pcall(function()
      owner:grant_op(h, holder, 'read', { terms = { delegable = true } })
    end),
    false
  )
end

-- Grant is the sole public non-custodial authority concept. Grant creation and
-- close tokens remain private implementation paths.
do
  assert_eq(Grant, require('fibers.grant'), 'Grant has a named module')
  assert_eq(Grant.new, nil, 'Grant construction should occur only through Scope:grant_op')
  assert_eq(fibers.Claim, nil, 'public close-token aliases should be absent')
  assert_eq(pcall(require, 'fibers.lifetime.custody'), false, 'Custody has no facade module')
  local atoms_ok = pcall(require, 'fibers.atoms')
  assert_eq(atoms_ok, false, 'the obsolete atoms aggregate is absent')
end

print('tests/test_scope_grants.lua: ok')
