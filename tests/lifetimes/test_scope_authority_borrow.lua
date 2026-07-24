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
local FibersLease = require('fibers.resource.lease')
local FibersRegion = require('fibers.lifetime.region')
local FibersScope = require('fibers.scope')
local FibersFlow = require('fibers.resource.flow')
local Settlement = require('fibers.lifetime.settlement')

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

-- Owned live custody grants authority; claimed custody suspends ordinary use.
do
  local owner = FibersScope.new('authority-owner')
  local h = FibersRegion.handle('authority-owned')
  local live_auth, claimed_auth, restored_auth
  fibers.run(function()
    fibers.perform(owner:admit_op(h))
    live_auth = fibers.perform(maybe(owner:authorise_op(h, 'write')))
    local claim = fibers.perform(owner:claim_op(h, { type = 'test', reason = 'authority' }))
    claimed_auth = fibers.perform(maybe(owner:authorise_op(h, 'write')))
    fibers.perform(owner:resolve_op(claim, { kind = 'restore' }))
    restored_auth = fibers.perform(maybe(owner:authorise_op(h, 'write')))
    fibers.perform(Settlement.retire_item_op(owner, h))
  end)
  assert_eq(live_auth, 'yes', 'live owned item should authorise use')
  assert_eq(claimed_auth, 'no', 'claimed item should not authorise ordinary use')
  assert_eq(restored_auth, 'yes', 'restored item should authorise again')
end

-- Borrowing grants authority without moving custody, and the borrow itself is
-- an owned obligation settled by the borrower scope.
do
  local owner = FibersScope.new('borrow-owner')
  local borrower = FibersScope.new('borrower')
  local h = FibersRegion.handle('borrow-subject')
  local borrow, subject_owner_after_borrow, read_auth, write_auth, borrow_owner, after_release
  fibers.run(function()
    fibers.perform(owner:admit_op(h))
    borrow = fibers.perform(owner:borrow_op(h, borrower, { 'read' }))
    subject_owner_after_borrow = h.owner
    borrow_owner = borrow.owner
    read_auth = fibers.perform(maybe(borrower:authorise_op(h, 'read')))
    write_auth = fibers.perform(maybe(borrower:authorise_op(h, 'write')))
    fibers.perform(borrower:seal_op('done'))
    fibers.perform(Settlement.retire_item_op(borrower, borrow, 'done'))
    after_release = fibers.perform(maybe(borrower:authorise_op(h, 'read')))
    fibers.perform(Settlement.retire_item_op(owner, h))
  end)
  assert_eq(subject_owner_after_borrow, owner:raw_region(), 'borrow should not move custody')
  assert_eq(borrow_owner, borrower:raw_region(), 'borrow handle should be owned by borrower')
  assert_eq(read_auth, 'yes', 'borrower should receive requested authority')
  assert_eq(write_auth, 'no', 'borrower should not receive unrequested authority')
  assert_eq(after_release, 'no', 'settled borrower scope should release borrowed authority')
end

-- Borrow compatibility is enforced by the Lease atom; this scope-level test
-- checks that compatible read borrows can coexist and are ordinary owned
-- obligations.
do
  local owner = FibersScope.new('borrow-compat-owner')
  local r1 = FibersScope.new('borrow-reader-1')
  local r2 = FibersScope.new('borrow-reader-2')
  local h = FibersRegion.handle('borrow-compat-subject')
  local read_read
  fibers.run(function()
    fibers.perform(owner:admit_op(h))
    local borrows = fibers.perform(Op.all({
      owner:borrow_op(h, r1, { 'read' }),
      owner:borrow_op(h, r2, { 'read' }),
    }):or_else(Op.always(false)))
    read_read = borrows and 'yes' or 'no'
    -- This test is only about coexisting borrows. Borrow release itself is
    -- covered above; avoiding manual policy here keeps the test algebraic.
  end)
  assert_eq(read_read, 'yes', 'compatible read borrows should commit together')
end

-- Flow endpoints are byte-operation capabilities; Scope authority governs
-- whether a scope is authorised to obtain/carry/borrow the capability, not each
-- individual byte operation through an already-held endpoint.  Borrowing a
-- reader grants read authority without moving custody.
do
  local owner = FibersScope.new('flow-authority-owner')
  local borrower = FibersScope.new('flow-authority-borrower')
  local flow = FibersFlow.new({ name = 'flow-authority', capacity = 8 })
  local direct_auth, borrowed_auth, borrowed_byte, borrowed_err, write_err
  fibers.run(function()
    local rt = FibersRuntime.current()
    fibers.perform(owner:admit_op(FibersRegion.Owned.tree(flow, flow._fibers_settle, {
      FibersRegion.Owned.inert(flow:inlet(), { role = 'writer' }),
      FibersRegion.Owned.inert(flow:outlet(), { role = 'reader' }),
    }, { role = 'flow' })))
    rt:with_scope(owner, function()
      local _n, err = fibers.perform(flow:inlet():write_op('ab'))
      write_err = err
    end)
    direct_auth = fibers.perform(maybe(borrower:authorise_op(flow:outlet(), 'read')))
    fibers.perform(owner:borrow_op(flow:outlet(), borrower, { 'read' }))
    borrowed_auth = fibers.perform(maybe(borrower:authorise_op(flow:outlet(), 'read')))
    rt:with_scope(borrower, function()
      borrowed_byte, borrowed_err = fibers.perform(flow:outlet():read_some_op(1))
    end)
    fibers.perform(Settlement.retire_item_op(owner, flow, 'done'))
  end)
  assert_eq(write_err, nil, 'owner should be able to write through owned inlet')
  assert_eq(direct_auth, 'no', 'borrower should not have read authority before borrowing')
  assert_eq(borrowed_auth, 'yes', 'borrowed reader authority should be visible to authorise_op')
  assert_eq(borrowed_byte, 'a', 'borrowed reader capability should read the first byte')
  assert_eq(borrowed_err, nil, 'borrowed read should not fail')
end

-- Compatibility leases are a named resource module; custody claims remain
-- internal so the two concepts cannot be confused.
do
  assert_eq(FibersLease, require('fibers.resource.lease'), 'Lease has a named resource module')
  assert_eq(fibers.Claim, nil, 'public Claim alias should be absent')
  local atoms_ok = pcall(require, 'fibers.atoms')
  assert_eq(atoms_ok, false, 'the obsolete atoms aggregate is absent')
end

print('tests/test_scope_authority_borrow.lua: ok')
