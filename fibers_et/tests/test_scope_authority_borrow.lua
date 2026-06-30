package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Settlement = require('fibers.internal.settlement')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end

local function maybe(op)
  return op:map(function() return 'yes' end):or_else(fibers.always('no'))
end

-- Owned live custody grants authority; claimed custody suspends ordinary use.
do
  local owner = fibers.Scope.new('authority-owner')
  local h = fibers.Region.handle('authority-owned')
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
  local owner = fibers.Scope.new('borrow-owner')
  local borrower = fibers.Scope.new('borrower')
  local h = fibers.Region.handle('borrow-subject')
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
  local owner = fibers.Scope.new('borrow-compat-owner')
  local r1 = fibers.Scope.new('borrow-reader-1')
  local r2 = fibers.Scope.new('borrow-reader-2')
  local h = fibers.Region.handle('borrow-compat-subject')
  local read_read
  fibers.run(function()
    fibers.perform(owner:admit_op(h))
    local borrows = fibers.perform(fibers.all({
      owner:borrow_op(h, r1, { 'read' }),
      owner:borrow_op(h, r2, { 'read' }),
    }):or_else(fibers.always(false)))
    read_read = borrows and 'yes' or 'no'
    -- This test is only about coexisting borrows. Borrow release itself is
    -- covered above; avoiding manual policy here keeps the test algebraic.
  end)
  assert_eq(read_read, 'yes', 'compatible read borrows should commit together')
end



-- Flow endpoints now consult current-scope authority when their owning Region
-- belongs to a Scope.  A borrower may read only after receiving a read borrow;
-- failed authority does not consume bytes from the flow.
do
  local owner = fibers.Scope.new('flow-authority-owner')
  local borrower = fibers.Scope.new('flow-authority-borrower')
  local flow = fibers.Flow.new({ name = 'flow-authority', capacity = 8 })
  local denied_err, borrowed_byte, borrowed_err, write_err
  fibers.run(function()
    local rt = fibers.Runtime.current()
    fibers.perform(owner:admit_op(fibers.Region.Owned.tree(flow, flow._fibers_settle, {
      fibers.Region.Owned.inert(flow:inlet(), { role = 'writer' }),
      fibers.Region.Owned.inert(flow:outlet(), { role = 'reader' }),
    }, { role = 'flow' })))
    rt:with_scope(owner, function()
      local _n, err = fibers.perform(flow:inlet():write_op('ab'))
      write_err = err
    end)
    rt:with_scope(borrower, function()
      local _byte, err = fibers.perform(flow:outlet():read_op(1))
      denied_err = err
    end)
    fibers.perform(owner:borrow_op(flow:outlet(), borrower, { 'read' }))
    rt:with_scope(borrower, function()
      borrowed_byte, borrowed_err = fibers.perform(flow:outlet():read_op(1))
    end)
    fibers.perform(Settlement.retire_item_op(owner, flow, 'done'))
  end)
  assert_eq(write_err, nil, 'owner should be able to write through owned inlet')
  assert_eq(denied_err, fibers.Flow.Errors.UNAUTHORISED, 'unborrowed scope should not read owned outlet')
  assert_eq(borrowed_byte, 'a', 'borrowed reader should read the first byte after authority is granted')
  assert_eq(borrowed_err, nil, 'borrowed read should not fail')
end

-- Lease is now the public atom name; public Claim has been removed so
-- custody claims and compatibility leases cannot be confused.
do
  assert_eq(fibers.Lease, require('fibers.atoms.lease'), 'top-level Lease should export the atom')
  assert_eq(require('fibers.atoms').Lease, fibers.Lease, 'atoms aggregate should export Lease')
  assert_eq(fibers.Claim, nil, 'public Claim alias should be removed')
  assert_eq(require('fibers.atoms').Claim, nil, 'atoms aggregate Claim alias should be removed')
end

print('tests/test_scope_authority_borrow.lua: ok')
