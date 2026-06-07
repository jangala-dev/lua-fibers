-- Ledger resource contract tests.

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Channel = require('fibers.channel')
local Ledger = require('fibers.resources.ledger')
local H = require('tests.resources.test_helpers')

local function test_ownership_transfer_commits_atomically_with_rendezvous()
  local rt = Runtime.new()
  local ledger = Ledger.new('asset-transfer', 'A')
  local ch = Channel.new('ownership-transfer-sync')
  local receiver, sender

  rt:spawn(function()
    receiver = rt:perform(
      ledger:transfer_op('A', 'B'):and_then(function()
        return ch:get_op(Op)
      end)
    )
  end, 'ownership-transfer-receiver')

  rt:spawn(function()
    sender = rt:perform(ch:put_op(Op, 'accepted'))
  end, 'ownership-transfer-sender')

  H.assert_status(rt:run(), 'found', 'ownership transfer commits as part of larger rendezvous')
  H.assert_eq(receiver, 'accepted')
  H.assert_eq(sender, true)
  H.assert_eq(ledger.owner, 'B', 'committed transfer moves ownership to B')
end

local function test_ownership_transfer_aborts_with_blocked_transaction()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ledger = Ledger.new('asset-abort', 'A')
  local ch = Channel.new('ownership-transfer-blocked')
  local got

  rt:spawn(function()
    got = rt:perform(
      ledger:transfer_op('A', 'B'):and_then(function()
        return ch:get_op(Op)
      end)
    )
  end, 'ownership-transfer-blocked-receiver')

  local status = rt:run()
  H.assert_uncommitted_status(status, 'blocked transaction does not commit ownership transfer')
  H.assert_eq(got, nil)
  H.assert_eq(ledger.owner, 'A', 'aborted transfer leaves old owner responsible')
  H.assert_eq(#H.obligation_entries(rt, 'settlement'), 0, 'aborted transfer produces no settlement')
end

local function test_ownership_transfer_losing_choice_branch_is_discarded()
  local rt = Runtime.new()
  local ledger = Ledger.new('asset-choice', 'A')
  local got

  rt:spawn(function()
    got = rt:perform(Op.choice(
      Op.always('winner'),
      ledger:transfer_op('A', 'B'):and_then(function()
        return ledger:close_op('B'):and_then(function()
          return Op.always('loser')
        end)
      end)
    ))
  end, 'ownership-choice-loser')

  H.assert_status(rt:run(), 'found')
  H.assert_eq(got, 'winner')
  H.assert_eq(ledger.owner, 'A', 'losing transfer branch has no ownership effect')
  H.assert_eq(ledger.settled_owner, nil, 'losing close/settlement branch has no consequence')
  H.assert_eq(#H.obligation_entries(rt, 'settlement'), 0, 'losing branch settlement is discarded')
end

local function test_settlement_follows_final_committed_owner()
  local rt = Runtime.new()
  local ledger = Ledger.new('asset-settle-new-owner', 'A')
  local got

  rt:spawn(function()
    got = rt:perform(
      ledger:transfer_op('A', 'B'):and_then(function()
        return ledger:close_op('B'):and_then(function()
          return ledger:owner_op()
        end)
      end)
    )
  end, 'ownership-settle-new-owner')

  H.assert_status(rt:run(), 'found')
  H.assert_eq(got, 'B', 'transaction sees final owner B')
  H.assert_eq(ledger.owner, 'B')
  H.assert_eq(ledger.closed.B, true)
  H.assert_eq(ledger.settled_owner, 'B', 'settlement responsibility moved to B')

  local settlements = H.obligation_entries(rt, 'settlement')
  H.assert_eq(#settlements, 1, 'committed close produces exactly one settlement')
  H.assert_eq(settlements[1].owner, 'B', 'settlement is for the final committed owner')
end

local function test_settlement_exactly_once_after_owner_already_closed()
  local ledger = Ledger.new('asset-settle-once', 'A')

  do
    local rt = Runtime.new()
    local closed
    rt:spawn(function() closed = rt:perform(ledger:close_op('A')) end, 'settlement-once-close-a')
    H.assert_status(rt:run(), 'found')
    H.assert_eq(closed, true)
    H.assert_eq(ledger.settled_owner, 'A')
    local settlements = H.obligation_entries(rt, 'settlement')
    H.assert_eq(#settlements, 1, 'first close settles once')
    H.assert_eq(settlements[1].owner, 'A')
  end

  do
    local rt = Runtime.new()
    local closed_again
    rt:spawn(function() closed_again = rt:perform(ledger:close_op('A')) end, 'settlement-once-close-a-again')
    H.assert_status(rt:run(), 'found')
    H.assert_eq(closed_again, true)
    H.assert_eq(ledger.settled_owner, 'A')
    H.assert_eq(#H.obligation_entries(rt, 'settlement'), 0, 'closing an already-settled owner does not publish another settlement')
  end
end

local function test_settled_ledger_cannot_be_transferred_after_close()
  local ledger = Ledger.new('asset-no-transfer-after-settlement', 'A')

  do
    local rt = Runtime.new()
    local closed
    rt:spawn(function() closed = rt:perform(ledger:close_op('A')) end, 'close-before-transfer')
    H.assert_status(rt:run(), 'found')
    H.assert_eq(closed, true)
    H.assert_eq(ledger.owner, 'A')
    H.assert_eq(ledger.settled_owner, 'A')
  end

  do
    local rt = Runtime.new({ quiet_deadlock = true })
    local moved
    rt:spawn(function() moved = rt:perform(ledger:transfer_op('A', 'B')) end, 'transfer-after-settlement')
    H.assert_uncommitted_status(rt:run(), 'settled ledger must not be resurrected by transfer')
    H.assert_eq(moved, nil)
    H.assert_eq(ledger.owner, 'A')
    H.assert_eq(ledger.settled_owner, 'A')
    H.assert_eq(#H.obligation_entries(rt, 'settlement'), 0)
  end
end

local function test_close_then_transfer_in_one_transaction_is_absent()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ledger = Ledger.new('asset-close-then-transfer-same-tx', 'A')
  local moved

  rt:spawn(function()
    moved = rt:perform(
      ledger:close_op('A'):and_then(function()
        return ledger:transfer_op('A', 'B')
      end)
    )
  end, 'close-then-transfer-same-tx')

  H.assert_uncommitted_status(rt:run(), 'closing the current owner must not be followed by transfer')
  H.assert_eq(moved, nil)
  H.assert_eq(ledger.owner, 'A')
  H.assert_eq(ledger.settled_owner, nil)
  H.assert_eq(ledger.closed.A, nil)
  H.assert_eq(#H.obligation_entries(rt, 'settlement'), 0)
end

local tests = {
  test_ownership_transfer_commits_atomically_with_rendezvous,
  test_ownership_transfer_aborts_with_blocked_transaction,
  test_ownership_transfer_losing_choice_branch_is_discarded,
  test_settlement_follows_final_committed_owner,
  test_settlement_exactly_once_after_owner_already_closed,
  test_settled_ledger_cannot_be_transferred_after_close,
  test_close_then_transfer_in_one_transaction_is_absent,
}

for i = 1, #tests do tests[i]() end
print('tests/resources/test_ledger.lua: ok')
