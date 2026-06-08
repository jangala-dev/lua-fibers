-- Combined public operation algebra contract tests.
-- External fibers algebra behaviour tests.
--

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Channel = require('fibers.channel')
local Cell = require('fibers.cell')
local TC = require('tests.consequence_helpers')

local pack_ = table.pack or function(...)
  return { n = select('#', ...), ... }
end

local function fail(msg)
  error(msg, 2)
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
  end
end

local function assert_truthy(value, msg)
  if not value then fail(msg or 'expected truthy value') end
end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag))
  end
  return status.value
end

local function assert_uncommitted_status(status, msg)
  local tag = status and status.tag
  if tag ~= 'absent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local function transaction_tags(rt)
  local out = {}
  for i = 1, #(rt.published_consequences or {}) do
    local log = rt.published_consequences[i]
    for j = 1, #(log.transaction or {}) do
      local c = log.transaction[j]
      out[#out + 1] = c.tag or c.kind or tostring(c[1])
    end
    for j = 1, #(log.obligation or {}) do
      local c = log.obligation[j]
      local payload = c.payload or {}
      local tag = payload.tag or payload.kind or c.tag
      if tag then out[#out + 1] = tag end
    end
  end
  return table.concat(out, ',')
end

local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local values = { n = 0 }
  rt:spawn_raw(function()
    values = pack_(rt:perform(op))
  end, 'one-perform')
  local status = rt:run()
  return status, values, rt
end

local function test_always_and_never()
  do
    local status, values = one_perform(Op.always('a', nil, 'c'))
    assert_status(status, 'found', 'always commits')
    assert_eq(values.n, 3, 'always preserves value arity')
    assert_eq(values[1], 'a')
    assert_eq(values[2], nil)
    assert_eq(values[3], 'c')
  end

  do
    local status, values = one_perform(Op.never(), { quiet_deadlock = true })
    assert_uncommitted_status(status, 'never cannot commit')
    assert_eq(values.n, 0, 'never does not resume participant')
  end
end

local function test_map_and_and_then_are_transactional()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'and-then-cell')
  local got

  rt:spawn_raw(function()
    got = rt:perform(
      Op.always(2)
        :map(function(v) return v + 3 end)
        :and_then(function(v)
          return cell:set_op(Op, v):and_then(function()
            return cell:get_op(Op)
          end)
        end)
    )
  end, 'map-and-then')

  assert_status(rt:run(), 'found')
  assert_eq(got, 5, 'and_then sees tentative state established earlier in the transaction')
  assert_eq(cell.value, 5, 'transaction commits final cell state')
end

local function test_and_then_is_all_or_nothing()
  local rt = Runtime.new({ quiet_deadlock = true })
  local cell = Cell.new(0, 'and-then-abort-cell')
  local ch = Channel.new('and-then-abort-channel')
  local got

  rt:spawn_raw(function()
    got = rt:perform(
      cell:set_op(Op, 7):and_then(function()
        return ch:get_op(Op)
      end)
    )
  end, 'and-then-blocked')

  local status = rt:run()
  assert_uncommitted_status(status, 'blocked second step prevents entire sequence from committing')
  assert_eq(cell.value, 0, 'first step of blocked and_then sequence is not committed')
  assert_eq(got, nil, 'participant is not resumed')
end

local function test_choice_selects_one_world_and_discards_loser()
  local rt = Runtime.new()
  local wraps = {}
  local got

  local winner = Op.emit(TC.tag('choice.winner')):and_then(function()
    return Op.always('winner'):wrap(function(v)
      wraps[#wraps + 1] = 'winner-wrap'
      return v
    end)
  end)

  local loser = Op.emit(TC.tag('choice.loser')):and_then(function()
    return Op.always('loser'):wrap(function(v)
      wraps[#wraps + 1] = 'loser-wrap'
      return v
    end)
  end)

  rt:spawn_raw(function() got = rt:perform(Op.choice(winner, loser)) end, 'choice-winner')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(transaction_tags(rt), 'choice.winner', 'losing branch consequence is discarded')
  assert_eq(table.concat(wraps, ','), 'winner-wrap', 'losing branch wrap is not run')

  local status2, values2 = one_perform(Op.choice(Op.never(), Op.always('right')))
  assert_status(status2, 'found', 'choice may select right branch when left is impossible')
  assert_eq(values2[1], 'right')
end

local function test_or_else_preference_and_fallback()
  do
    local rt = Runtime.new()
    local got
    local primary = Op.emit(TC.tag('or_else.primary')):and_then(function() return Op.always('primary') end)
    local fallback = Op.emit(TC.tag('or_else.fallback')):and_then(function() return Op.always('fallback') end)
    rt:spawn_raw(function() got = rt:perform(primary:or_else(fallback)) end, 'or-else-primary')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'primary')
    assert_eq(transaction_tags(rt), 'or_else.primary', 'fallback effects are discarded when primary can commit')
  end

  do
    local status, values, rt = one_perform(Op.never():or_else(Op.emit(TC.tag('or_else.fallback')):and_then(function()
      return Op.always('fallback')
    end)))
    assert_status(status, 'found', 'or_else commits fallback when primary is absent')
    assert_eq(values[1], 'fallback')
    assert_eq(transaction_tags(rt), 'or_else.fallback')
  end
end


local function test_or_else_primary_absence_is_checked_across_other_participants()
  do
    local rt = Runtime.new()
    local ch = Channel.new('or-else-cross-absent-no-partner')
    local receiver

    rt:spawn_raw(function()
      receiver = rt:perform(
        ch:get_op(Op)
          :map(function(v) return 'primary:' .. v end)
          :or_else(Op.emit(TC.tag('or_else.cross.no_partner.fallback')):and_then(function()
            return Op.always('fallback')
          end))
      )
    end, 'or-else-cross-no-partner-receiver')

    assert_status(rt:run(), 'found', 'or_else fallback commits when rendezvous primary has no partner')
    assert_eq(receiver, 'fallback', 'blocked primary is absent when no other participant can satisfy it')
    assert_eq(transaction_tags(rt), 'or_else.cross.no_partner.fallback', 'fallback consequence is published only in the absent-primary case')
  end

  do
    local rt = Runtime.new()
    local ch1 = Channel.new('or-else-cross-partial-absent-1')
    local ch2 = Channel.new('or-else-cross-partial-absent-2')
    local receiver, sender1

    local primary = Op.all({ ch1:get_op(Op), ch2:get_op(Op) })
      :map(function(rows)
        return rows[1][1] .. '+' .. rows[2][1]
      end)

    local fallback = Op.emit(TC.tag('or_else.cross.partial_absent.fallback')):and_then(function()
      return Op.always('fallback')
    end)

    rt:spawn_raw(function()
      receiver = rt:perform(primary:or_else(fallback))
    end, 'or-else-cross-partial-absent-receiver')
    rt:spawn_raw(function() sender1 = rt:perform(ch1:put_op(Op, 'a')) end, 'or-else-cross-partial-absent-sender-1')

    assert_status(rt:run(), 'found', 'or_else fallback commits when the whole primary cannot be satisfied')
    assert_eq(receiver, 'fallback', 'a partially satisfiable primary is still absent as a whole')
    assert_eq(sender1, nil, 'stray partner for an abandoned primary does not commit')
    assert_eq(transaction_tags(rt), 'or_else.cross.partial_absent.fallback', 'fallback consequence is published for globally absent primary')
  end

  do
    local rt = Runtime.new()
    local ch = Channel.new('or-else-cross-participant')
    local receiver, sender

    rt:spawn_raw(function()
      receiver = rt:perform(
        ch:get_op(Op)
          :map(function(v) return 'primary:' .. v end)
          :or_else(Op.emit(TC.tag('or_else.cross.fallback')):and_then(function()
            return Op.always('fallback')
          end))
      )
    end, 'or-else-cross-receiver')

    rt:spawn_raw(function()
      sender = rt:perform(ch:put_op(Op, 'payload'))
    end, 'or-else-cross-sender')

    assert_status(rt:run(), 'found', 'or_else primary may be satisfied by another participant')
    assert_eq(receiver, 'primary:payload', 'fallback is not used when another participant can satisfy the primary')
    assert_eq(sender, true, 'partner in the preferred primary transaction commits')
    assert_eq(transaction_tags(rt), '', 'fallback consequence is not published')
  end

  do
    local rt = Runtime.new()
    local ch1 = Channel.new('or-else-cross-all-1')
    local ch2 = Channel.new('or-else-cross-all-2')
    local receiver, sender1, sender2

    local primary = Op.all({ ch1:get_op(Op), ch2:get_op(Op) })
      :map(function(rows)
        return rows[1][1] .. '+' .. rows[2][1]
      end)

    local fallback = Op.emit(TC.tag('or_else.cross.all.fallback')):and_then(function()
      return Op.always('fallback')
    end)

    rt:spawn_raw(function()
      receiver = rt:perform(primary:or_else(fallback))
    end, 'or-else-cross-all-receiver')
    rt:spawn_raw(function() sender1 = rt:perform(ch1:put_op(Op, 'a')) end, 'or-else-cross-all-sender-1')
    rt:spawn_raw(function() sender2 = rt:perform(ch2:put_op(Op, 'b')) end, 'or-else-cross-all-sender-2')

    assert_status(rt:run(), 'found', 'or_else primary absence considers all required external participants')
    assert_eq(receiver, 'a+b', 'multi-requirement primary beats fallback when partners exist')
    assert_eq(sender1, true)
    assert_eq(sender2, true)
    assert_eq(transaction_tags(rt), '', 'multi-requirement fallback consequence is not published')
  end
end

local function test_or_else_retries_stale_primary_instead_of_committing_fallback()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'or-else-stale-primary-cell')
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(cell:update_op(Op, function(v) return v + 1 end))
  end, 'stale-primary-first-updater')

  rt:spawn_raw(function()
    b = rt:perform(
      cell:update_op(Op, function(v) return v + 1 end)
        :map(function() return 'primary' end)
        :or_else(Op.always('fallback'))
    )
  end, 'stale-primary-preferred-updater')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'primary update is retried against fresh state')
  assert_eq(a, 1)
  assert_eq(b, 'primary', 'fallback is not used merely because the parked primary became stale')
  assert_truthy((rt.stats.refreshes or 0) >= 1, 'stale frontier was refreshed')
end

local function test_guard_is_delayed_and_participates_in_search()
  local constructed = 0
  local rt = Runtime.new()
  local got

  local guarded = Op.guard(function()
    constructed = constructed + 1
    return Op.always('guarded')
  end)

  assert_eq(constructed, 0, 'guard callback is not run when the expression is constructed')
  rt:spawn_raw(function() got = rt:perform(guarded) end, 'guarded')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'guarded')
  assert_truthy(constructed >= 1, 'guard callback runs when the operation is attempted')
end

local function test_wrap_is_post_commit_and_not_transactional_sequence()
  local cell = Cell.new(0, 'wrap-phase-cell')
  local timeline = {}
  local got
  local published = {}
  local rt = Runtime.new({
    services = {
      test_tag = function(tag)
        if #published == 0 then
          timeline[#timeline + 1] = 'publish'
          assert_eq(cell.value, 9, 'resource state is committed before consequences are observed')
        end
        published[#published + 1] = tag
      end,
    },
  })

  local op = Op.emit(TC.tag('wrap.before')):and_then(function()
    return cell:set_op(Op, 9):and_then(function()
      return Op.emit(TC.tag('wrap.after')):and_then(function()
        return Op.always('value'):wrap(function(v)
          timeline[#timeline + 1] = 'wrap'
          assert_eq(cell.value, 9, 'wrap runs after commit')
          return v .. ':wrapped'
        end)
      end)
    end)
  end)

  rt:spawn_raw(function()
    got = rt:perform(op)
    timeline[#timeline + 1] = 'resume'
  end, 'wrap-phase')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'value:wrapped')
  assert_eq(transaction_tags(rt), 'wrap.before,wrap.after', 'explicit transaction consequences preserve syntax order across resource access')
  assert_eq(table.concat(published, ','), 'wrap.before,wrap.after', 'explicit transaction consequences preserve syntax order across resource access')
  assert_eq(table.concat(timeline, ','), 'publish,wrap,resume', 'publish happens before wrap, wrap before participant continuation resumes')

  local boundary = Op.always('x'):wrap(function(v) return v end)
  local ok_bind = pcall(function() return boundary:and_then(function() return Op.always('bad') end) end)
  local ok_map = pcall(function() return boundary:map(function(v) return v end) end)
  assert_eq(ok_bind, false, 'wrapped boundary cannot be transactionally sequenced')
  assert_eq(ok_map, false, 'wrapped boundary cannot be transactionally mapped')
end

local function test_tensor_all_and_internal_rendezvous_topology()
  do
    local ch = Channel.new('tensor-internal')
    local status, rows = one_perform(Op.tensor({ ch:put_op(Op, 'payload'), ch:get_op(Op) }))
    assert_status(status, 'found', 'tensor permits internal rendezvous')
    assert_eq(rows[1][1][1], true, 'send lane returns true')
    assert_eq(rows[1][2][1], 'payload', 'receive lane gets sent payload')
  end

  do
    local ch = Channel.new('all-no-internal')
    local status = one_perform(Op.all({ ch:put_op(Op, 'payload'), ch:get_op(Op) }), { quiet_deadlock = true })
    assert_uncommitted_status(status, 'all does not permit internal rendezvous between its own lanes')
  end

  do
    local rt = Runtime.new()
    local ch1 = Channel.new('all-external-1')
    local ch2 = Channel.new('all-external-2')
    local rows
    rt:spawn_raw(function() rows = rt:perform(Op.all({ ch1:get_op(Op), ch2:get_op(Op) })) end, 'all-receiver')
    rt:spawn_raw(function() rt:perform(ch1:put_op(Op, 'a')) end, 'all-sender-a')
    rt:spawn_raw(function() rt:perform(ch2:put_op(Op, 'b')) end, 'all-sender-b')
    assert_status(rt:run(), 'found', 'all can combine multiple external requirements')
    assert_eq(rows[1][1], 'a')
    assert_eq(rows[2][1], 'b')
  end

  do
    local status, rows = one_perform(Op.tensor({ Op.always('a'), Op.always('b') }))
    assert_status(status, 'found')
    assert_eq(rows[1][1][1], 'a')
    assert_eq(rows[1][2][1], 'b')
  end
end

local function test_with_nack_external_behaviour()
  do
    local ref
    local rt = Runtime.new()
    local got
    rt:spawn_raw(function()
      got = rt:perform(Op.with_nack(function(nack)
        ref = nack.obligation
        return Op.always('selected')
      end))
    end, 'with-nack-selected')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'selected')
    assert_truthy(ref, 'with_nack exposes a nack obligation to its builder')

    local status, values = one_perform(Op._nack(ref), { quiet_deadlock = true })
    assert_uncommitted_status(status, 'nack does not fire for a selected protected occurrence')
    assert_eq(values.n, 0)
  end

  do
    local ref
    local rt = Runtime.new()
    local got
    rt:spawn_raw(function()
      got = rt:perform(Op.choice(
        Op.always('winner'),
        Op.with_nack(function(nack)
          ref = nack.obligation
          return Op.emit(TC.tag('nack.loser.effect')):and_then(function() return Op.always('loser') end)
        end)
      ))
    end, 'with-nack-loser')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'winner')
    assert_eq(transaction_tags(rt), '', 'losing protected branch effects are discarded')
    assert_truthy(ref, 'losing protected branch published a nack obligation')

    local status, values = one_perform(Op._nack(ref))
    assert_status(status, 'found', 'nack fires for a losing protected occurrence')
    assert_eq(values[1], true)
  end
end

local function test_contending_cell_updates_retry()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'contended-cell')
  local a, b

  rt:spawn_raw(function() a = rt:perform(cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-update-a')
  rt:spawn_raw(function() b = rt:perform(cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-update-b')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'both contending updates eventually commit')
  assert_eq(a, 1)
  assert_eq(b, 2)
  assert_truthy((rt.stats.refreshes or 0) >= 1, 'second update refreshed after first commit dirtied the cell')
end

local function test_conflicting_parallel_cell_writes_do_not_commit_partially()
  local rt = Runtime.new({ quiet_deadlock = true })
  local cell = Cell.new(0, 'conflicting-parallel-cell')
  local got

  rt:spawn_raw(function()
    got = rt:perform(Op.tensor({ cell:set_op(Op, 1), cell:set_op(Op, 2) }))
  end, 'parallel-conflict')

  local status = rt:run()
  assert_uncommitted_status(status, 'conflicting parallel writes cannot commit')
  assert_eq(cell.value, 0, 'conflicting write transaction leaves cell unchanged')
  assert_eq(got, nil, 'participant is not resumed')
end

local function test_canonical_te_triple_swap()
  local rt = Runtime.new()
  local ab = Channel.new('triple-ab')
  local bc = Channel.new('triple-bc')
  local ca = Channel.new('triple-ca')
  local a_got, b_got, c_got

  rt:spawn_raw(function()
    local rows = rt:perform(Op.tensor({ ab:put_op(Op, 'A'), ca:get_op(Op) }))
    a_got = rows[2][1]
  end, 'triple-A')

  rt:spawn_raw(function()
    local rows = rt:perform(Op.tensor({ ab:get_op(Op), bc:put_op(Op, 'B') }))
    b_got = rows[1][1]
  end, 'triple-B')

  rt:spawn_raw(function()
    local rows = rt:perform(Op.tensor({ bc:get_op(Op), ca:put_op(Op, 'C') }))
    c_got = rows[1][1]
  end, 'triple-C')

  assert_status(rt:run(), 'found', 'three-party transactional cycle commits')
  assert_eq(a_got, 'C')
  assert_eq(b_got, 'A')
  assert_eq(c_got, 'B')
end

local function test_triple_swap_does_not_partially_commit_when_a_party_is_missing()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ab = Channel.new('partial-triple-ab')
  local bc = Channel.new('partial-triple-bc')
  local ca = Channel.new('partial-triple-ca')
  local a_got, b_got

  rt:spawn_raw(function()
    local rows = rt:perform(Op.tensor({ ab:put_op(Op, 'A'), ca:get_op(Op) }))
    a_got = rows[2][1]
  end, 'partial-triple-A')

  rt:spawn_raw(function()
    local rows = rt:perform(Op.tensor({ ab:get_op(Op), bc:put_op(Op, 'B') }))
    b_got = rows[1][1]
  end, 'partial-triple-B')

  local status = rt:run()
  assert_uncommitted_status(status, 'triple swap cannot partially commit with a missing participant')
  assert_eq(a_got, nil)
  assert_eq(b_got, nil)
end



local function test_multi_value_bind_map_and_wrap_preserve_arity()
  local status, values = one_perform(
    Op.always('A', 'B')
      :and_then(function(a, b)
        return Op.always(b, a, 'C')
      end)
      :map(function(x, y, z)
        return x .. y .. z, x, z
      end)
      :wrap(function(joined, x, z)
        return joined .. ':' .. x .. ':' .. z, z
      end)
  )

  assert_status(status, 'found')
  assert_eq(values.n, 2, 'multi-value arity survives bind, map, and wrap')
  assert_eq(values[1], 'BAC:B:C')
  assert_eq(values[2], 'C')
end

local function test_deferred_map_and_bind_after_rendezvous()
  do
    local rt = Runtime.new()
    local ch = Channel.new('deferred-map-channel')
    local got
    rt:spawn_raw(function()
      got = rt:perform(ch:get_op(Op):map(function(v) return v .. '!' end))
    end, 'deferred-map-receiver')
    rt:spawn_raw(function() rt:perform(ch:put_op(Op, 'payload')) end, 'deferred-map-sender')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'payload!', 'map is applied after deferred rendezvous values are known')
  end

  do
    local rt = Runtime.new()
    local ch = Channel.new('deferred-bind-channel')
    local cell = Cell.new('unset', 'deferred-bind-cell')
    local got
    rt:spawn_raw(function()
      got = rt:perform(ch:get_op(Op):and_then(function(v)
        return cell:set_op(Op, v):and_then(function()
          return cell:get_op(Op):map(function(current) return current .. ':done' end)
        end)
      end))
    end, 'deferred-bind-receiver')
    rt:spawn_raw(function() rt:perform(ch:put_op(Op, 'message')) end, 'deferred-bind-sender')
    assert_status(rt:run(), 'found')
    assert_eq(cell.value, 'message')
    assert_eq(got, 'message:done', 'bind after rendezvous participates in the same transaction')
  end
end

local function test_choice_discards_loser_resource_state_even_when_loser_is_locally_possible()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'choice-loser-resource-cell')
  local got

  local winner = Op.always('winner')
  local loser = cell:set_op(Op, 99):map(function() return 'loser' end)

  rt:spawn_raw(function() got = rt:perform(Op.choice(winner, loser)) end, 'choice-loser-resource')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner', 'left choice branch is selected when both branches are locally possible')
  assert_eq(cell.value, 0, 'unselected choice branch does not commit its resource effects')
end

local function test_choice_blocked_branch_does_not_partially_commit_before_right_branch_wins()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'choice-blocked-left-cell')
  local ch = Channel.new('choice-blocked-left-channel')
  local got

  local blocked_left = cell:set_op(Op, 1):and_then(function()
    return ch:get_op(Op)
  end)
  local right = cell:set_op(Op, 2):map(function() return 'right' end)

  rt:spawn_raw(function() got = rt:perform(Op.choice(blocked_left, right)) end, 'choice-blocked-left')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'right')
  assert_eq(cell.value, 2, 'blocked losing branch does not leak earlier transactional writes')
end

local function test_tensor_is_parallel_not_sequential_for_cell_views()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'tensor-view-cell')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      cell:set_op(Op, 1),
      cell:get_op(Op),
    }))
  end, 'tensor-cell-views')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 1, 'tensor commits the selected write')
  assert_eq(rows[1][1], true)
  assert_eq(rows[2][1], 0, 'sibling tensor lane sees the shared pre-transaction view, not a sequential write')
end

local function test_tensor_or_else_prefers_internal_rendezvous_over_fallback()
  local ch = Channel.new('tensor-or-else-internal')
  local status, values = one_perform(Op.tensor({
    ch:get_op(Op):or_else(Op.always('fallback')),
    ch:put_op(Op, 'internal-message'),
  }))

  assert_status(status, 'found')
  local rows = values[1]
  assert_eq(rows[1][1], 'internal-message', 'or_else primary may be satisfied by a tensor-internal rendezvous')
  assert_eq(rows[2][1], true)
end

local function test_or_else_primary_rendezvous_beats_fallback_when_partner_exists()
  local rt = Runtime.new()
  local ch = Channel.new('or-else-external-primary')
  local cell = Cell.new(0, 'or-else-external-primary-cell')
  local got

  rt:spawn_raw(function()
    got = rt:perform(ch:get_op(Op):or_else(cell:set_op(Op, 99):map(function() return 'fallback' end)))
  end, 'or-else-external-receiver')
  rt:spawn_raw(function() rt:perform(ch:put_op(Op, 'from-sender')) end, 'or-else-external-sender')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'from-sender')
  assert_eq(cell.value, 0, 'fallback branch is not committed when primary rendezvous can commit')
end

local function test_or_else_blocked_primary_discards_partial_state_before_fallback()
  local rt = Runtime.new()
  local ch = Channel.new('or-else-blocked-primary-channel')
  local cell = Cell.new(0, 'or-else-blocked-primary-cell')
  local got

  local primary = cell:set_op(Op, 1):and_then(function()
    return ch:get_op(Op)
  end)
  local fallback = cell:set_op(Op, 2):map(function() return 'fallback' end)

  rt:spawn_raw(function() got = rt:perform(primary:or_else(fallback)) end, 'or-else-blocked-primary')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(cell.value, 2, 'fallback commits without leaking the blocked primary write')
end

local function test_choice_backtracks_around_product_conflict()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'choice-product-conflict-cell')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.tensor({
      cell:set_op(Op, 1):map(function() return 'write-1' end):choice(Op.always('no-write')),
      cell:set_op(Op, 2),
    }))
  end, 'choice-product-conflict')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'search backtracks from a locally possible branch that conflicts in the product')
  assert_eq(rows[1][1], 'no-write')
  assert_eq(rows[2][1], true)
end

local function test_guard_memo_survives_refresh_of_stale_frontier()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'guard-refresh-cell')
  local guard_calls = 0
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(cell:update_op(Op, function(v) return v + 1 end))
  end, 'guard-refresh-first-updater')

  rt:spawn_raw(function()
    b = rt:perform(Op.guard(function()
      guard_calls = guard_calls + 1
      return cell:update_op(Op, function(v) return v + 1 end)
    end))
  end, 'guard-refresh-guarded-updater')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2)
  assert_eq(a, 1)
  assert_eq(b, 2)
  assert_eq(guard_calls, 1, 'refresh reuses the guarded expression for the same attempt rather than rerunning guard effects')
  assert_truthy((rt.stats.refreshes or 0) >= 1, 'test exercised stale frontier refresh')
end

local function test_losing_or_else_fallback_settles_with_nack_as_lost()
  local ref
  local rt = Runtime.new()
  local got

  rt:spawn_raw(function()
    got = rt:perform(Op.always('primary'):or_else(Op.with_nack(function(nack)
      ref = nack.obligation
      return Op.always('fallback')
    end)))
  end, 'or-else-fallback-not-entered')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'primary')
  assert_eq(ref, nil, 'residual or_else does not construct a fallback that is not opened')
end

local function test_nack_does_not_fire_while_protected_attempt_is_still_pending()
  local rt = Runtime.new({ quiet_deadlock = true })
  local ch = Channel.new('pending-nack-channel')
  local ref
  local protected_got, nack_got

  rt:spawn_raw(function()
    protected_got = rt:perform(Op.with_nack(function(nack)
      ref = nack.obligation
      return ch:get_op(Op)
    end))
  end, 'pending-protected')

  rt:spawn_raw(function()
    nack_got = rt:perform(Op.guard(function()
      return Op._nack(ref)
    end))
  end, 'premature-nack')

  local status = rt:run()
  assert_uncommitted_status(status, 'a nack is not enabled merely because its protected attempt is pending')
  assert_eq(protected_got, nil)
  assert_eq(nack_got, nil)
  assert_truthy(ref, 'protected attempt published a nack obligation')
end

local function test_multiple_wraps_run_in_order_after_publication()
  local timeline = {}
  local rt = Runtime.new({
    services = {
      test_tag = function()
        timeline[#timeline + 1] = 'publish'
      end,
    },
  })
  local got

  rt:spawn_raw(function()
    got = rt:perform(
      Op.emit(TC.tag('multi-wrap')):and_then(function()
        return Op.always('x')
      end)
        :wrap(function(v)
          timeline[#timeline + 1] = 'wrap1'
          return v .. '1'
        end)
        :wrap(function(v)
          timeline[#timeline + 1] = 'wrap2'
          return v .. '2'
        end)
    )
    timeline[#timeline + 1] = 'resume'
  end, 'multi-wrap')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'x12')
  assert_eq(table.concat(timeline, ','), 'publish,wrap1,wrap2,resume', 'multiple wraps run in order after publication and before fibre continuation')
end


local function test_wrap_may_perform_new_transaction_after_commit()
  local cell = Cell.new(0, 'wrap-nested-perform-cell')
  local timeline = {}
  local got
  local rt = Runtime.new({
    services = {
      test_tag = function(tag)
        timeline[#timeline + 1] = 'publish:' .. tag
      end,
    },
  })

  local outer = Op.emit(TC.tag('outer')):and_then(function()
    return cell:set_op(Op, 1):and_then(function()
      return Op.always('a'):wrap(function(v)
        timeline[#timeline + 1] = 'wrap-start'
        assert_eq(cell.value, 1, 'wrap runs after the outer resource commit')
        local y = rt:perform(Op.emit(TC.tag('inner')):and_then(function()
          return Op.always('b')
        end))
        timeline[#timeline + 1] = 'wrap-end'
        return v .. y
      end)
    end)
  end)

  rt:spawn_raw(function()
    got = rt:perform(outer)
    timeline[#timeline + 1] = 'resume'
  end, 'wrap-nested-perform')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'ab')
  assert_eq(cell.value, 1)
  assert_eq(table.concat(timeline, ','), 'publish:outer,wrap-start,publish:inner,wrap-end,resume', 'wrap may perform a fresh transaction after the outer commit')
end

local function test_wrap_failure_does_not_rollback_committed_resources()
  local cell = Cell.new(0, 'wrap-failure-cell')
  local rt = Runtime.new()

  rt:spawn_raw(function()
    rt:perform(cell:set_op(Op, 5):and_then(function()
      return Op.always('x'):wrap(function()
        error('wrap boom')
      end)
    end))
  end, 'wrap-failure')

  local ok, err = pcall(function() return rt:run() end)
  assert_eq(ok, false, 'wrap failure is reported to the caller')
  assert_truthy(tostring(err):match('wrap boom'), 'wrap failure reports the original error')
  assert_eq(cell.value, 5, 'committed resource state is not rolled back by wrap failure')
end


local function test_product_lane_wraps_apply_inside_out_after_commit()
  local timeline = {}
  local rt = Runtime.new({
    services = {
      test_tag = function(tag)
        timeline[#timeline + 1] = 'publish:' .. tag
      end,
    },
  })
  local ch_a = Channel.new('wrap-product-a')
  local ch_b = Channel.new('wrap-product-b')
  local got, put_a, put_b

  rt:spawn_raw(function()
    got = rt:perform(
      Op.emit(TC.tag('outer')):and_then(function()
        return Op.all({
          ch_a:get_op(Op):wrap(function(v)
            timeline[#timeline + 1] = 'wrap-a'
            local suffix = rt:perform(Op.emit(TC.tag('inner-a')):and_then(function()
              return Op.always('!')
            end))
            return v .. suffix
          end),
          ch_b:get_op(Op):wrap(function(v)
            timeline[#timeline + 1] = 'wrap-b'
            local suffix = rt:perform(Op.emit(TC.tag('inner-b')):and_then(function()
              return Op.always('?')
            end))
            return v .. suffix
          end),
        }):wrap(function(rows)
          timeline[#timeline + 1] = 'wrap-outer'
          rows.outer = true
          return rows
        end)
      end)
    )
    timeline[#timeline + 1] = 'resume'
  end, 'wrapped-product-receiver')

  rt:spawn_raw(function() put_a = rt:perform(ch_a:put_op(Op, 'a')) end, 'wrapped-product-sender-a')
  rt:spawn_raw(function() put_b = rt:perform(ch_b:put_op(Op, 'b')) end, 'wrapped-product-sender-b')

  assert_status(rt:run(), 'found')
  assert_eq(put_a, true)
  assert_eq(put_b, true)
  assert_eq(got[1][1], 'a!')
  assert_eq(got[2][1], 'b?')
  assert_eq(got.outer, true, 'outer wrap sees product after lane-local wraps')
  assert_eq(table.concat(timeline, ','), 'publish:outer,wrap-a,publish:inner-a,wrap-b,publish:inner-b,wrap-outer,resume', 'lane wraps run left-to-right inside the outer wrap after commit')
end

local function test_tensor_lane_wraps_apply_after_internal_rendezvous()
  local ch = Channel.new('wrap-tensor-internal')
  local timeline = {}
  local status, values = one_perform(
    Op.tensor({
      ch:put_op(Op, 'payload'):wrap(function(v)
        timeline[#timeline + 1] = 'put-wrap'
        return v and 'sent' or 'not-sent'
      end),
      ch:get_op(Op):wrap(function(v)
        timeline[#timeline + 1] = 'get-wrap'
        return v .. ':got'
      end),
    }):wrap(function(rows)
      timeline[#timeline + 1] = 'outer-wrap'
      return rows
    end)
  )

  assert_status(status, 'found')
  assert_eq(values[1][1][1], 'sent')
  assert_eq(values[1][2][1], 'payload:got')
  assert_eq(table.concat(timeline, ','), 'put-wrap,get-wrap,outer-wrap', 'tensor lane wraps run after internal rendezvous resolution')
end

local function test_map_and_and_then_reject_operations_containing_wraps()
  local wrapped_product = Op.all({ Op.always('x'):wrap(function(v) return v end) })
  local ok_map = pcall(function()
    return wrapped_product:map(function(rows) return rows end)
  end)
  local ok_bind = pcall(function()
    return wrapped_product:and_then(function() return Op.always('next') end)
  end)
  local ok_outer_wrap = pcall(function()
    return wrapped_product:wrap(function(rows) return rows end)
  end)

  assert_eq(ok_map, false, 'map cannot consume a product containing a post-commit wrap')
  assert_eq(ok_bind, false, 'and_then cannot consume a product containing a post-commit wrap')
  assert_eq(ok_outer_wrap, true, 'outer wrap remains valid on a product containing lane-local wraps')
end

local tests = {
  test_always_and_never,
  test_multi_value_bind_map_and_wrap_preserve_arity,
  test_deferred_map_and_bind_after_rendezvous,
  test_map_and_and_then_are_transactional,
  test_and_then_is_all_or_nothing,
  test_choice_selects_one_world_and_discards_loser,
  test_choice_discards_loser_resource_state_even_when_loser_is_locally_possible,
  test_choice_blocked_branch_does_not_partially_commit_before_right_branch_wins,
  test_or_else_preference_and_fallback,
  test_or_else_primary_absence_is_checked_across_other_participants,
  test_tensor_or_else_prefers_internal_rendezvous_over_fallback,
  test_or_else_primary_rendezvous_beats_fallback_when_partner_exists,
  test_or_else_blocked_primary_discards_partial_state_before_fallback,
  test_or_else_retries_stale_primary_instead_of_committing_fallback,
  test_guard_is_delayed_and_participates_in_search,
  test_guard_memo_survives_refresh_of_stale_frontier,
  test_wrap_is_post_commit_and_not_transactional_sequence,
  test_multiple_wraps_run_in_order_after_publication,
  test_wrap_may_perform_new_transaction_after_commit,
  test_wrap_failure_does_not_rollback_committed_resources,
  test_product_lane_wraps_apply_inside_out_after_commit,
  test_tensor_lane_wraps_apply_after_internal_rendezvous,
  test_map_and_and_then_reject_operations_containing_wraps,
  test_tensor_all_and_internal_rendezvous_topology,
  test_tensor_is_parallel_not_sequential_for_cell_views,
  test_choice_backtracks_around_product_conflict,
  test_with_nack_external_behaviour,
  test_losing_or_else_fallback_settles_with_nack_as_lost,
  test_nack_does_not_fire_while_protected_attempt_is_still_pending,
  test_contending_cell_updates_retry,
  test_conflicting_parallel_cell_writes_do_not_commit_partially,
  test_canonical_te_triple_swap,
  test_triple_swap_does_not_partially_commit_when_a_party_is_missing,
}

for i = 1, #tests do
  tests[i]()
end

print('tests/test_op.lua: core algebra contract ok')


-- Additional subtle algebra contract tests.
-- Fiendish external fibers algebra conformance tests.
--
-- These tests deliberately use only the public-facing algebra/runtime/resources.
-- They are intended to catch local, greedy, non-backtracking, stale-frontier,
-- or non-reusable-expression implementations.
--
-- Expected public modules:
--   fibers.op
--   fibers.runtime
--   fibers.channel
--   fibers.cell
--   fibers.resources.ledger

package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Channel = require('fibers.channel')
local Cell = require('fibers.cell')
local TC = require('tests.consequence_helpers')
local Ledger = require('fibers.resources.ledger')

local pack_ = table.pack or function(...)
  return { n = select('#', ...), ... }
end

local unpack_ = table.unpack or unpack

local function fail(msg) error(msg, 2) end

local function tostring_value(v)
  if type(v) == 'table' then return '<table>' end
  return tostring(v)
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring_value(expected) .. ', got ' .. tostring_value(actual))
  end
end

local function assert_truthy(value, msg)
  if not value then fail(msg or 'expected truthy value') end
end

local function assert_falsy(value, msg)
  if value then fail((msg or 'expected falsy value') .. ': got ' .. tostring_value(value)) end
end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(status and status.tag) .. ' (' .. tostring(status and status.reason) .. ')')
  end
  return status.value
end

local function assert_uncommitted_status(status, msg)
  local tag = status and status.tag
  if tag ~= 'absent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local function one_perform(op, opts)
  local rt = Runtime.new(opts or {})
  local values = { n = 0 }
  rt:spawn_raw(function()
    values = pack_(rt:perform(op))
  end, 'one-perform')
  local status = rt:run()
  return status, values, rt
end

local function transaction_tags(rt)
  local out = {}
  for i = 1, #(rt.published_consequences or {}) do
    local log = rt.published_consequences[i]
    for j = 1, #(log.transaction or {}) do
      local c = log.transaction[j]
      out[#out + 1] = c.tag or c.kind or tostring(c[1])
    end
    for j = 1, #(log.obligation or {}) do
      local c = log.obligation[j]
      local payload = c.payload or {}
      local tag = payload.tag or payload.kind or c.tag
      if tag then out[#out + 1] = tag end
    end
  end
  return table.concat(out, ',')
end

local function obligation_entries(rt, kind)
  local out = {}
  for i = 1, #(rt.published_consequences or {}) do
    local log = rt.published_consequences[i]
    for j = 1, #(log.obligation or {}) do
      local c = log.obligation[j]
      if kind == nil or c.kind == kind or c.tag == kind then out[#out + 1] = c.payload or c end
    end
  end
  return out
end

local function assert_set_eq(actual, expected, msg)
  if #actual ~= #expected then
    fail((msg or 'set length mismatch') .. ': expected ' .. #expected .. ', got ' .. #actual)
  end
  local seen = {}
  for i = 1, #actual do seen[tostring(actual[i])] = (seen[tostring(actual[i])] or 0) + 1 end
  for i = 1, #expected do
    local k = tostring(expected[i])
    if not seen[k] or seen[k] == 0 then
      fail((msg or 'set mismatch') .. ': missing ' .. k)
    end
    seen[k] = seen[k] - 1
  end
  for k, n in pairs(seen) do
    if n ~= 0 then fail((msg or 'set mismatch') .. ': unexpected ' .. k) end
  end
end

local function close_current_owner(ledger)
  return ledger:owner_op():and_then(function(owner)
    return ledger:close_op(owner):and_then(function()
      return Op.always(owner)
    end)
  end)
end

-- A guard is a pre-attempt constructor, not a permanent global memo for the
-- lifetime of an expression value. A reusable first-class transaction expression
-- must be re-attemptable.
local function test_guard_is_per_attempt_not_permanent_memo()
  local runs = 0
  local guarded = Op.guard(function()
    runs = runs + 1
    return Op.always('attempt-' .. tostring(runs))
  end)

  local s1, v1 = one_perform(guarded)
  assert_status(s1, 'found', 'first guarded attempt commits')
  assert_eq(v1[1], 'attempt-1')

  local s2, v2 = one_perform(guarded)
  assert_status(s2, 'found', 'same guarded expression is reusable')
  assert_eq(v2[1], 'attempt-2', 'guard body is rerun for a new attempt')
  assert_eq(runs, 2, 'guard was run once per perform attempt')
end

-- with_nack is also attempt-scoped. Reusing a protected transaction expression
-- must not reuse an old selected/lost obligation cell.
local function test_with_nack_reused_expression_gets_fresh_obligation()
  local refs = {}
  local protected = Op.with_nack(function(nack)
    refs[#refs + 1] = nack.obligation
    return Op.always('protected')
  end)

  do
    local status, values = one_perform(protected)
    assert_status(status, 'found', 'first protected attempt commits')
    assert_eq(values[1], 'protected')
    assert_truthy(refs[1], 'first attempt created a nack obligation')
  end

  do
    local status, values = one_perform(Op.choice(Op.always('winner'), protected))
    assert_status(status, 'found', 'second use of protected expression participates in choice')
    assert_eq(values[1], 'winner')
    assert_truthy(refs[2], 'second attempt created a fresh nack obligation')
    assert_truthy(refs[2] ~= refs[1], 'nack obligations are not reused across attempts')

    local s_lost, v_lost = one_perform(Op._nack(refs[2]))
    assert_status(s_lost, 'found', 'fresh losing protected occurrence has an observable nack')
    assert_eq(v_lost[1], true)

    local s_old = one_perform(Op._nack(refs[1]), { quiet_deadlock = true })
    assert_uncommitted_status(s_old, 'selected obligation from first attempt does not later fire')
  end
end

-- Fallback absence is global: if one primary candidate fails, the runtime must
-- keep searching other primary worlds before falling back.
local function test_or_else_primary_second_candidate_beats_fallback()
  local rt = Runtime.new()
  local cell = Cell.new('init', 'primary-second-candidate-cell')
  local bad = Channel.new('primary-second-bad')
  local good = Channel.new('primary-second-good')
  local got, bad_sender, good_sender

  local bad_primary = bad:get_op(Op):and_then(function(v)
    return cell:set_op(Op, 'bad'):and_then(function()
      return Op.always('bad:' .. tostring(v))
    end)
  end)
  local good_primary = good:get_op(Op):and_then(function(v)
    return cell:set_op(Op, 'good'):and_then(function()
      return Op.always('good:' .. tostring(v))
    end)
  end)
  local primary = Op.choice(bad_primary, good_primary)
  local fallback = Op.emit(TC.tag('bad.fallback')):and_then(function()
    return cell:set_op(Op, 'fallback'):and_then(function() return Op.always('fallback') end)
  end)

  rt:spawn_raw(function() got = rt:perform(primary:or_else(fallback)) end, 'receiver')
  rt:spawn_raw(function()
    bad_sender = rt:perform(Op.all({ bad:put_op(Op, 'payload'), cell:set_op(Op, 'conflict') }))
  end, 'bad-conflicting-sender')
  rt:spawn_raw(function() good_sender = rt:perform(good:put_op(Op, 'payload')) end, 'good-sender')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'good:payload', 'second primary candidate commits before fallback')
  assert_eq(good_sender, true)
  assert_falsy(bad_sender, 'conflicting primary partner does not commit')
  assert_eq(cell.value, 'good')
  assert_eq(transaction_tags(rt), '', 'fallback consequence is not published')
end

-- The primary can become available only if another participant backtracks to a
-- non-first branch. Fallback must wait for that global possibility.
local function test_or_else_primary_needs_partner_backtracking()
  local rt = Runtime.new()
  local wanted = Channel.new('partner-backtrack-wanted')
  local dead = Channel.new('partner-backtrack-dead')
  local receiver, partner

  rt:spawn_raw(function()
    receiver = rt:perform(
      wanted:get_op(Op)
        :map(function(v) return 'primary:' .. tostring(v) end)
        :or_else(Op.emit(TC.tag('partner.backtrack.fallback')):and_then(function()
          return Op.always('fallback')
        end))
    )
  end, 'receiver')

  rt:spawn_raw(function()
    partner = rt:perform(Op.choice(dead:put_op(Op, 'dead'), wanted:put_op(Op, 'ok')))
  end, 'partner')

  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:ok', 'partner backtracking makes primary globally available')
  assert_eq(partner, true)
  assert_eq(transaction_tags(rt), '', 'fallback does not publish')
end

-- Rendezvous and resource compatibility must be solved together.
local function test_or_else_primary_resource_conflict_backtracks_partner_branch()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'primary-resource-conflict-cell')
  local ch = Channel.new('primary-resource-conflict-channel')
  local receiver, partner

  local primary = ch:get_op(Op):and_then(function(v)
    return cell:set_op(Op, 1):and_then(function()
      return Op.always('primary:' .. tostring(v))
    end)
  end)
  local fallback = Op.emit(TC.tag('resource.conflict.fallback')):and_then(function()
    return Op.always('fallback')
  end)

  rt:spawn_raw(function() receiver = rt:perform(primary:or_else(fallback)) end, 'receiver')
  rt:spawn_raw(function()
    partner = rt:perform(Op.choice(
      Op.all({ ch:put_op(Op, 'bad'), cell:set_op(Op, 2) }),
      Op.all({ ch:put_op(Op, 'good'), cell:set_op(Op, 1) })
    ))
  end, 'partner')

  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:good', 'runtime backtracks through a conflicting partner branch')
  assert_truthy(partner ~= nil, 'compatible partner branch commits')
  assert_eq(cell.value, 1)
  assert_eq(transaction_tags(rt), '', 'fallback consequence is not published')
end

local function test_or_else_absent_primary_discards_tentative_writes()
  local rt = Runtime.new()
  local cell = Cell.new('initial', 'absent-primary-discards-writes-cell')
  local ch = Channel.new('absent-primary-discards-writes-channel')
  local got

  local primary = cell:set_op(Op, 'primary'):and_then(function()
    return ch:get_op(Op)
  end)
  local fallback = cell:set_op(Op, 'fallback'):and_then(function()
    return Op.always('fallback')
  end)

  rt:spawn_raw(function() got = rt:perform(primary:or_else(fallback)) end, 'receiver')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(cell.value, 'fallback', 'tentative write in absent primary is discarded')
end

local function test_losing_branch_emit_wrap_and_nack_do_not_cross_contaminate()
  local rt = Runtime.new()
  local wraps = 0
  local ref
  local got

  local loser = Op.with_nack(function(nack)
    ref = nack.obligation
    return Op.emit(TC.tag('loser.emit')):and_then(function()
      return Op.always('loser'):wrap(function(v)
        wraps = wraps + 1
        return v
      end)
    end)
  end)

  rt:spawn_raw(function()
    got = rt:perform(Op.choice(Op.always('winner'), loser))
  end, 'choice')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(transaction_tags(rt), '', 'losing branch emit is discarded')
  assert_eq(wraps, 0, 'losing branch wrap is not run')
  assert_truthy(ref, 'losing protected branch published a nack obligation')

  local s_nack, v_nack = one_perform(Op._nack(ref))
  assert_status(s_nack, 'found', 'losing protected branch nack can fire after loss')
  assert_eq(v_nack[1], true)
end

local function test_nested_or_else_uses_nearest_available_world()
  do
    local rt = Runtime.new()
    local ch = Channel.new('nested-or-else-primary')
    local got, sender
    local op = ch:get_op(Op):map(function(v) return 'primary:' .. v end)
      :or_else(Op.always('inner'))
      :or_else(Op.always('outer'))
    rt:spawn_raw(function() got = rt:perform(op) end, 'receiver')
    rt:spawn_raw(function() sender = rt:perform(ch:put_op(Op, 'ok')) end, 'sender')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'primary:ok')
    assert_eq(sender, true)
  end

  do
    local status, values = one_perform(
      Channel.new('nested-or-else-absent'):get_op(Op)
        :or_else(Op.always('inner'))
        :or_else(Op.always('outer'))
    )
    assert_status(status, 'found')
    assert_eq(values[1], 'inner', 'inner fallback wins when primary is absent')
  end

  do
    local status, values = one_perform(Op.never():or_else(Op.never()):or_else(Op.always('outer')))
    assert_status(status, 'found')
    assert_eq(values[1], 'outer', 'outer fallback wins only when inner expression is absent')
  end
end

local function test_tensor_internal_and_external_rendezvous_must_all_close()
  local rt = Runtime.new()
  local internal = Channel.new('tensor-subtle-internal')
  local external = Channel.new('tensor-subtle-external')
  local a, b

  local op = Op.tensor({
    internal:put_op(Op, 'inside'),
    internal:get_op(Op),
    external:get_op(Op),
  }):map(function(rows)
    return tostring(rows[2][1]) .. '+' .. tostring(rows[3][1])
  end)

  rt:spawn_raw(function() a = rt:perform(op) end, 'tensor-root')
  rt:spawn_raw(function() b = rt:perform(external:put_op(Op, 'outside')) end, 'external-partner')

  assert_status(rt:run(), 'found')
  assert_eq(a, 'inside+outside', 'tensor root commits only after internal and external rendezvous close')
  assert_eq(b, true)
end

local function test_all_does_not_allow_internal_rendezvous_even_nested()
  local ch = Channel.new('all-nested-no-internal')
  local status = one_perform(Op.all({
    Op.tensor({ Op.always('irrelevant') }),
    ch:put_op(Op, 'x'),
    ch:get_op(Op),
  }), { quiet_deadlock = true })
  assert_uncommitted_status(status, 'all still does not permit internal rendezvous between its own lanes')
end

local function test_triple_swap_with_decoy_does_not_greedily_partially_commit()
  local rt = Runtime.new()
  local ab = Channel.new('triple-decoy-ab')
  local bc = Channel.new('triple-decoy-bc')
  local ca = Channel.new('triple-decoy-ca')
  local a, b, c, decoy

  rt:spawn_raw(function()
    a = rt:perform(Op.all({ ab:put_op(Op, 'A'), ca:get_op(Op) }):map(function(rows) return rows[2][1] end))
  end, 'A')
  rt:spawn_raw(function()
    b = rt:perform(Op.all({ bc:put_op(Op, 'B'), ab:get_op(Op) }):map(function(rows) return rows[2][1] end))
  end, 'B')
  rt:spawn_raw(function()
    c = rt:perform(Op.all({ ca:put_op(Op, 'C'), bc:get_op(Op) }):map(function(rows) return rows[2][1] end))
  end, 'C')
  rt:spawn_raw(function()
    decoy = rt:perform(ab:get_op(Op))
  end, 'decoy')

  assert_status(rt:run(), 'found')
  assert_eq(a, 'C')
  assert_eq(b, 'A')
  assert_eq(c, 'B')
  assert_eq(decoy, nil, 'decoy partial communication is not committed')
end

local function test_dependent_cell_updates_are_serialisable_under_freshness()
  local rt = Runtime.new()
  local cell = Cell.new(0, 'dependent-freshness-cell')
  local returns = {}

  local function op()
    return cell:get_op(Op):and_then(function(old)
      return cell:set_op(Op, old + 1):and_then(function()
        return Op.always(old)
      end)
    end)
  end

  for i = 1, 3 do
    rt:spawn_raw(function()
      returns[#returns + 1] = rt:perform(op())
    end, 'dependent-updater-' .. tostring(i))
  end

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 3, 'all dependent increments commit')
  assert_set_eq(returns, { 0, 1, 2 }, 'each dependent transaction observed a serial old value')
end

local function test_competing_ownership_transfers_have_one_winner()
  local ledger = Ledger.new('competing-transfer-ledger', 'A')
  local rt = Runtime.new()
  local to_b, to_c

  rt:spawn_raw(function() to_b = rt:perform(ledger:transfer_op('A', 'B')) end, 'transfer-B')
  rt:spawn_raw(function() to_c = rt:perform(ledger:transfer_op('A', 'C')) end, 'transfer-C')

  assert_status(rt:run(), 'found')
  assert_truthy(ledger.owner == 'B' or ledger.owner == 'C', 'ownership has exactly one final owner')
  assert_truthy((to_b == true and to_c == nil) or (to_c == true and to_b == nil), 'only one competing transfer commits')

  local rt2 = Runtime.new()
  local closed_owner
  rt2:spawn_raw(function() closed_owner = rt2:perform(close_current_owner(ledger)) end, 'close-final-owner')
  assert_status(rt2:run(), 'found')
  assert_eq(closed_owner, ledger.owner)
  local settlements = obligation_entries(rt2, 'settlement')
  assert_eq(#settlements, 1, 'closing final owner emits one settlement')
  assert_eq(settlements[1].owner, ledger.owner, 'settlement follows the winning owner')
end

local function test_transfer_close_or_else_settles_under_correct_owner()
  do
    local ledger = Ledger.new('transfer-close-primary', 'A')
    local rt = Runtime.new()
    local result
    local primary = ledger:transfer_op('A', 'B'):and_then(function()
      return ledger:close_op('B'):and_then(function()
        return ledger:owner_op()
      end)
    end)
    local fallback = Op.emit(TC.tag('bad.close-A-fallback')):and_then(function()
      return ledger:close_op('A'):and_then(function() return Op.always('fallback') end)
    end)
    rt:spawn_raw(function() result = rt:perform(primary:or_else(fallback)) end, 'transfer-close')
    assert_status(rt:run(), 'found')
    assert_eq(result, 'B')
    assert_eq(ledger.owner, 'B')
    assert_eq(ledger.settled_owner, 'B')
    assert_eq(transaction_tags(rt), '', 'fallback close-A branch did not run')
    local settlements = obligation_entries(rt, 'settlement')
    assert_eq(#settlements, 1)
    assert_eq(settlements[1].owner, 'B')
  end

  do
    local ledger = Ledger.new('transfer-close-fallback', 'A')
    local rt = Runtime.new()
    local result
    local primary = ledger:transfer_op('C', 'B'):and_then(function()
      return ledger:close_op('B'):and_then(function() return Op.always('primary') end)
    end)
    local fallback = ledger:close_op('A'):and_then(function() return Op.always('fallback') end)
    rt:spawn_raw(function() result = rt:perform(primary:or_else(fallback)) end, 'transfer-close-fallback')
    assert_status(rt:run(), 'found')
    assert_eq(result, 'fallback')
    assert_eq(ledger.owner, 'A')
    assert_eq(ledger.settled_owner, 'A')
    local settlements = obligation_entries(rt, 'settlement')
    assert_eq(#settlements, 1)
    assert_eq(settlements[1].owner, 'A')
  end
end

local function test_settlement_exactly_once_under_competing_close_retry()
  local ledger = Ledger.new('settle-once-competing-close', 'A')
  local rt = Runtime.new()
  local a, b

  rt:spawn_raw(function() a = rt:perform(ledger:close_op('A')) end, 'close-a-1')
  rt:spawn_raw(function() b = rt:perform(ledger:close_op('A')) end, 'close-a-2')

  assert_status(rt:run(), 'found')
  assert_eq(a, true)
  assert_eq(b, true, 'second close may observe already-closed owner and still complete')
  assert_eq(ledger.settled_owner, 'A')
  local settlements = obligation_entries(rt, 'settlement')
  assert_eq(#settlements, 1, 'settlement is emitted exactly once despite competing close attempts')
  assert_eq(settlements[1].owner, 'A')
end

local tests = {
  { 'guard is per-attempt, not permanent memo', test_guard_is_per_attempt_not_permanent_memo },
  { 'with_nack reused expression gets fresh obligation', test_with_nack_reused_expression_gets_fresh_obligation },
  { 'or_else primary second candidate beats fallback', test_or_else_primary_second_candidate_beats_fallback },
  { 'or_else primary needs partner backtracking', test_or_else_primary_needs_partner_backtracking },
  { 'or_else primary resource conflict backtracks partner branch', test_or_else_primary_resource_conflict_backtracks_partner_branch },
  { 'or_else absent primary discards tentative writes', test_or_else_absent_primary_discards_tentative_writes },
  { 'losing branch emit/wrap/nack do not cross-contaminate', test_losing_branch_emit_wrap_and_nack_do_not_cross_contaminate },
  { 'nested or_else uses nearest available world', test_nested_or_else_uses_nearest_available_world },
  { 'tensor internal and external rendezvous must all close', test_tensor_internal_and_external_rendezvous_must_all_close },
  { 'all does not allow internal rendezvous even nested', test_all_does_not_allow_internal_rendezvous_even_nested },
  { 'triple swap with decoy does not partially commit', test_triple_swap_with_decoy_does_not_greedily_partially_commit },
  { 'dependent cell updates are serialisable under freshness', test_dependent_cell_updates_are_serialisable_under_freshness },
  { 'competing ownership transfers have one winner', test_competing_ownership_transfers_have_one_winner },
  { 'transfer-close or_else settles under correct owner', test_transfer_close_or_else_settles_under_correct_owner },
  { 'settlement exactly once under competing close retry', test_settlement_exactly_once_under_competing_close_retry },
}

local failures = {}
for i = 1, #tests do
  local name, fn = tests[i][1], tests[i][2]
  local ok, err = pcall(fn)
  if ok then
    io.write('ok ', i, ' - ', name, '\n')
  else
    failures[#failures + 1] = { i = i, name = name, err = err }
    io.write('not ok ', i, ' - ', name, ': ', tostring(err), '\n')
  end
end

if #failures > 0 then
  error('external fibers subtle algebra tests failed: ' .. tostring(#failures) .. ' failure(s)', 0)
end

print('tests/test_op.lua: subtle algebra contract ok')

print('tests/test_op.lua: ok')
