-- Combined public option algebra contract tests.
-- External fibers algebra behaviour tests.
--

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
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')
local TC = require('tests.support.effect_helpers')

local function new_runtime(opts)
  opts = opts or {}
  local tags = {}
  local host = opts.host or {}
  local previous = host.test_tag
  host.test_tag = function(tag, payload)
    tags[#tags + 1] = tag
    if previous then
      return previous(tag, payload)
    end
  end
  opts.host = host
  local rt = Runtime.new(opts)
  rt._test_tags = tags
  return rt
end

local function update_cell(cell, fn)
  return cell:read_op():and_then(function(old)
    local new = fn(old)
    return cell:write_op(new):map(function()
      return new, old
    end)
  end)
end

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
  if not value then
    fail(msg or 'expected truthy value')
  end
end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
    )
  end
  return status.value
end

local function assert_uncommitted_status(status, msg)
  local tag = status and status.tag
  if tag ~= 'quiescent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local function transaction_tags(rt)
  return table.concat(rt._test_tags or {}, ',')
end

local function one_perform(op, opts)
  local rt = new_runtime(opts or {})
  local values = { n = 0 }
  rt:spawn_raw(function()
    values = pack_(rt:perform(op))
  end, 'one-perform')
  local status = rt:run()
  return status, values, rt
end

local function test_canonical_algebra_vocabulary()
  assert_eq(Op.always().kind, 'always', 'always is the canonical value term')
  assert_eq(
    Op.always():and_then(function()
      return Op.always()
    end).kind,
    'and_then',
    'and_then is the canonical sequencing term'
  )
  assert_eq(
    Op.guard(function()
      return Op.always()
    end).kind,
    'guard',
    'guard is the canonical delayed-construction term'
  )
  assert_eq(
    Op.never():or_else(Op.always()).kind,
    'or_else',
    'or_else is the canonical residual fallback term'
  )
  assert_eq(Op.each({ Op.always() }).kind, 'product', 'each is the canonical independent product term')
  assert_eq(
    Op.together({ Op.always() }).kind,
    'product',
    'together is the canonical interacting product term'
  )
  assert_eq(type(Op.named_each), 'function', 'named_each is the canonical named independent product')
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
  local rt = new_runtime()
  local cell = Cell.new(0, 'and-then-cell')
  local got

  rt:spawn_raw(function()
    got = rt:perform(Op.always(2)
      :map(function(v)
        return v + 3
      end)
      :and_then(function(v)
        return cell:write_op(v):and_then(function()
          return cell:read_op()
        end)
      end))
  end, 'map-and-then')

  assert_status(rt:run(), 'found')
  assert_eq(got, 5, 'and_then sees tentative state established earlier in the transaction')
  assert_eq(cell.value, 5, 'transaction commits final cell state')
end

local function test_and_then_is_all_or_nothing()
  local rt = new_runtime({ quiet_deadlock = true })
  local cell = Cell.new(0, 'and-then-abort-cell')
  local ch = Rendezvous.new('and-then-abort-rendezvous')
  local got

  rt:spawn_raw(function()
    got = rt:perform(cell:write_op(7):and_then(function()
      return ch:get_op()
    end))
  end, 'and-then-blocked')

  local status = rt:run()
  assert_uncommitted_status(status, 'blocked second step prevents entire sequence from committing')
  assert_eq(cell.value, 0, 'first step of blocked and_then sequence is not committed')
  assert_eq(got, nil, 'participant is not resumed')
end

local function test_choice_selects_one_world_and_discards_loser()
  local rt = new_runtime({ choice_seed = 2 })
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

  rt:spawn_raw(function()
    got = rt:perform(Op.choice(winner, loser))
  end, 'choice-winner')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner')
  assert_eq(transaction_tags(rt), 'choice.winner', 'losing branch effect is discarded')
  assert_eq(table.concat(wraps, ','), 'winner-wrap', 'losing branch wrap is not run')

  local status2, values2 = one_perform(Op.choice(Op.never(), Op.always('right')))
  assert_status(status2, 'found', 'choice may select right branch when left is impossible')
  assert_eq(values2[1], 'right')
end

local function test_or_else_preference_and_fallback()
  do
    local rt = new_runtime()
    local got
    local primary = Op.emit(TC.tag('or_else.primary')):and_then(function()
      return Op.always('primary')
    end)
    local fallback = Op.emit(TC.tag('or_else.fallback')):and_then(function()
      return Op.always('fallback')
    end)
    rt:spawn_raw(function()
      got = rt:perform(primary:or_else(fallback))
    end, 'or-else-primary')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'primary')
    assert_eq(
      transaction_tags(rt),
      'or_else.primary',
      'fallback effects are discarded when primary can commit'
    )
  end

  do
    local status, values, rt =
      one_perform(Op.never():or_else(Op.emit(TC.tag('or_else.fallback')):and_then(function()
        return Op.always('fallback')
      end)))
    assert_status(status, 'found', 'or_else commits fallback when primary is absent')
    assert_eq(values[1], 'fallback')
    assert_eq(transaction_tags(rt), 'or_else.fallback')
  end
end

local function test_or_else_primary_absence_is_checked_across_other_participants()
  do
    local rt = new_runtime()
    local ch = Rendezvous.new('or-else-cross-absent-no-partner')
    local receiver

    rt:spawn_raw(function()
      receiver = rt:perform(ch:get_op()
        :map(function(v)
          return 'primary:' .. v
        end)
        :or_else(Op.emit(TC.tag('or_else.cross.no_partner.fallback')):and_then(function()
          return Op.always('fallback')
        end)))
    end, 'or-else-cross-no-partner-receiver')

    assert_status(rt:run(), 'found', 'or_else fallback commits when rendezvous primary has no partner')
    assert_eq(receiver, 'fallback', 'blocked primary is absent when no other participant can satisfy it')
    assert_eq(
      transaction_tags(rt),
      'or_else.cross.no_partner.fallback',
      'fallback effect is discharged only in the absent-primary case'
    )
  end

  do
    local rt = new_runtime()
    local ch1 = Rendezvous.new('or-else-cross-partial-absent-1')
    local ch2 = Rendezvous.new('or-else-cross-partial-absent-2')
    local receiver, sender1

    local primary = Op.each({ ch1:get_op(), ch2:get_op() }):map(function(rows)
      return rows[1][1] .. '+' .. rows[2][1]
    end)

    local fallback = Op.emit(TC.tag('or_else.cross.partial_absent.fallback')):and_then(function()
      return Op.always('fallback')
    end)

    rt:spawn_raw(function()
      receiver = rt:perform(primary:or_else(fallback))
    end, 'or-else-cross-partial-absent-receiver')
    rt:spawn_raw(function()
      sender1 = rt:perform(ch1:put_op('a'))
    end, 'or-else-cross-partial-absent-sender-1')

    assert_status(rt:run(), 'found', 'or_else fallback commits when the whole primary cannot be satisfied')
    assert_eq(receiver, 'fallback', 'a partially satisfiable primary is still absent as a whole')
    assert_eq(sender1, nil, 'stray partner for an abandoned primary does not commit')
    assert_eq(
      transaction_tags(rt),
      'or_else.cross.partial_absent.fallback',
      'fallback effect is discharged for globally absent primary'
    )
  end

  do
    local rt = new_runtime()
    local ch = Rendezvous.new('or-else-cross-participant')
    local receiver, sender

    rt:spawn_raw(function()
      receiver = rt:perform(ch:get_op()
        :map(function(v)
          return 'primary:' .. v
        end)
        :or_else(Op.emit(TC.tag('or_else.cross.fallback')):and_then(function()
          return Op.always('fallback')
        end)))
    end, 'or-else-cross-receiver')

    rt:spawn_raw(function()
      sender = rt:perform(ch:put_op('payload'))
    end, 'or-else-cross-sender')

    assert_status(rt:run(), 'found', 'or_else primary may be satisfied by another participant')
    assert_eq(
      receiver,
      'primary:payload',
      'fallback is not used when another participant can satisfy the primary'
    )
    assert_eq(sender, true, 'partner in the preferred primary transaction commits')
    assert_eq(transaction_tags(rt), '', 'fallback effect is not discharged')
  end

  do
    local rt = new_runtime()
    local ch1 = Rendezvous.new('or-else-cross-each-1')
    local ch2 = Rendezvous.new('or-else-cross-each-2')
    local receiver, sender1, sender2

    local primary = Op.each({ ch1:get_op(), ch2:get_op() }):map(function(rows)
      return rows[1][1] .. '+' .. rows[2][1]
    end)

    local fallback = Op.emit(TC.tag('or_else.cross.all.fallback')):and_then(function()
      return Op.always('fallback')
    end)

    rt:spawn_raw(function()
      receiver = rt:perform(primary:or_else(fallback))
    end, 'or-else-cross-each-receiver')
    rt:spawn_raw(function()
      sender1 = rt:perform(ch1:put_op('a'))
    end, 'or-else-cross-each-sender-1')
    rt:spawn_raw(function()
      sender2 = rt:perform(ch2:put_op('b'))
    end, 'or-else-cross-each-sender-2')

    assert_status(rt:run(), 'found', 'or_else primary absence considers all required external participants')
    assert_eq(receiver, 'a+b', 'multi-requirement primary beats fallback when partners exist')
    assert_eq(sender1, true)
    assert_eq(sender2, true)
    assert_eq(transaction_tags(rt), '', 'multi-requirement fallback effect is not discharged')
  end
end

local function test_or_else_retries_stale_primary_instead_of_committing_fallback()
  local rt = new_runtime()
  local cell = Cell.new(0, 'or-else-stale-primary-cell')
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end, 'stale-primary-first-updater')

  rt:spawn_raw(function()
    b = rt:perform(update_cell(cell, function(v)
        return v + 1
      end)
      :map(function()
        return 'primary'
      end)
      :or_else(Op.always('fallback')))
  end, 'stale-primary-preferred-updater')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'primary update is retried against fresh state')
  assert_eq(a, 1)
  assert_eq(b, 'primary', 'fallback is not used merely because the parked primary became stale')
end

local function test_guard_is_delayed_and_participates_in_search()
  local constructed = 0
  local rt = new_runtime()
  local got

  local guarded = Op.guard(function()
    constructed = constructed + 1
    return Op.always('guarded')
  end)

  assert_eq(constructed, 0, 'guard callback is not run when the expression is constructed')
  rt:spawn_raw(function()
    got = rt:perform(guarded)
  end, 'guarded')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'guarded')
  assert_truthy(constructed >= 1, 'guard callback runs when the option is attempted')
end

local function test_wrap_is_post_commit_and_not_transactional_sequence()
  local cell = Cell.new(0, 'wrap-phase-cell')
  local timeline = {}
  local got
  local discharged = {}
  local rt = new_runtime({
    host = {
      test_tag = function(tag)
        if #discharged == 0 then
          timeline[#timeline + 1] = 'discharge'
          assert_eq(cell.value, 9, 'resource state is committed before effects are observed')
        end
        discharged[#discharged + 1] = tag
      end,
    },
  })

  local op = Op.emit(TC.tag('wrap.before')):and_then(function()
    return cell:write_op(9):and_then(function()
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
  assert_eq(
    transaction_tags(rt),
    'wrap.before,wrap.after',
    'explicit transaction effects preserve syntax order across resource access'
  )
  assert_eq(
    table.concat(discharged, ','),
    'wrap.before,wrap.after',
    'explicit transaction effects preserve syntax order across resource access'
  )
  assert_eq(
    table.concat(timeline, ','),
    'discharge,wrap,resume',
    'discharge happens before wrap, wrap before participant continuation resumes'
  )

  local boundary = Op.always('x'):wrap(function(v)
    return v
  end)
  local ok_and_then = pcall(function()
    return boundary:and_then(function()
      return Op.always('bad')
    end)
  end)
  local ok_map = pcall(function()
    return boundary:map(function(v)
      return v
    end)
  end)
  assert_eq(ok_and_then, false, 'wrapped boundary cannot be transactionally sequenced')
  assert_eq(ok_map, false, 'wrapped boundary cannot be transactionally mapped')
end

local function test_each_and_together_internal_rendezvous_topology()
  do
    local ch = Rendezvous.new('together-internal')
    local status, rows = one_perform(Op.together({ ch:put_op('payload'), ch:get_op() }))
    assert_status(status, 'found', 'together permits internal rendezvous')
    assert_eq(rows[1][1][1], true, 'send lane returns true')
    assert_eq(rows[1][2][1], 'payload', 'receive lane gets sent payload')
  end

  do
    local ch = Rendezvous.new('each-no-internal')
    local status = one_perform(Op.each({ ch:put_op('payload'), ch:get_op() }), { quiet_deadlock = true })
    assert_uncommitted_status(status, 'each does not permit internal rendezvous between its own lanes')
  end

  do
    local rt = new_runtime()
    local ch1 = Rendezvous.new('each-external-1')
    local ch2 = Rendezvous.new('each-external-2')
    local rows
    rt:spawn_raw(function()
      rows = rt:perform(Op.each({ ch1:get_op(), ch2:get_op() }))
    end, 'each-receiver')
    rt:spawn_raw(function()
      rt:perform(ch1:put_op('a'))
    end, 'each-sender-a')
    rt:spawn_raw(function()
      rt:perform(ch2:put_op('b'))
    end, 'each-sender-b')
    assert_status(rt:run(), 'found', 'each can combine multiple external requirements')
    assert_eq(rows[1][1], 'a')
    assert_eq(rows[2][1], 'b')
  end

  do
    local status, rows = one_perform(Op.together({ Op.always('a'), Op.always('b') }))
    assert_status(status, 'found')
    assert_eq(rows[1][1][1], 'a')
    assert_eq(rows[1][2][1], 'b')
  end
end

local function test_contending_cell_updates_retry()
  local rt = new_runtime()
  local cell = Cell.new(0, 'contended-cell')
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end, 'cell-update-a')
  rt:spawn_raw(function()
    b = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end, 'cell-update-b')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'both contending updates eventually commit')
  assert_eq(a, 1)
  assert_eq(b, 2)
end

local function test_conflicting_parallel_cell_writes_do_not_commit_partially()
  local rt = new_runtime({ quiet_deadlock = true })
  local cell = Cell.new(0, 'conflicting-parallel-cell')
  local got

  rt:spawn_raw(function()
    got = rt:perform(Op.together({ cell:write_op(1), cell:write_op(2) }))
  end, 'parallel-conflict')

  local status = rt:run()
  assert_uncommitted_status(status, 'conflicting parallel writes cannot commit')
  assert_eq(cell.value, 0, 'conflicting write transaction leaves cell unchanged')
  assert_eq(got, nil, 'participant is not resumed')
end

local function test_canonical_te_triple_swap()
  local rt = new_runtime()
  local ab = Rendezvous.new('triple-ab')
  local bc = Rendezvous.new('triple-bc')
  local ca = Rendezvous.new('triple-ca')
  local a_got, b_got, c_got

  rt:spawn_raw(function()
    local rows = rt:perform(Op.together({ ab:put_op('A'), ca:get_op() }))
    a_got = rows[2][1]
  end, 'triple-A')

  rt:spawn_raw(function()
    local rows = rt:perform(Op.together({ ab:get_op(), bc:put_op('B') }))
    b_got = rows[1][1]
  end, 'triple-B')

  rt:spawn_raw(function()
    local rows = rt:perform(Op.together({ bc:get_op(), ca:put_op('C') }))
    c_got = rows[1][1]
  end, 'triple-C')

  assert_status(rt:run(), 'found', 'three-party transactional cycle commits')
  assert_eq(a_got, 'C')
  assert_eq(b_got, 'A')
  assert_eq(c_got, 'B')
end

local function test_triple_swap_does_not_partially_commit_when_a_party_is_missing()
  local rt = new_runtime({ quiet_deadlock = true })
  local ab = Rendezvous.new('partial-triple-ab')
  local bc = Rendezvous.new('partial-triple-bc')
  local ca = Rendezvous.new('partial-triple-ca')
  local a_got, b_got

  rt:spawn_raw(function()
    local rows = rt:perform(Op.together({ ab:put_op('A'), ca:get_op() }))
    a_got = rows[2][1]
  end, 'partial-triple-A')

  rt:spawn_raw(function()
    local rows = rt:perform(Op.together({ ab:get_op(), bc:put_op('B') }))
    b_got = rows[1][1]
  end, 'partial-triple-B')

  local status = rt:run()
  assert_uncommitted_status(status, 'triple swap cannot partially commit with a missing participant')
  assert_eq(a_got, nil)
  assert_eq(b_got, nil)
end

local function test_multi_value_and_then_map_and_wrap_preserve_arity()
  local status, values = one_perform(Op.always('A', 'B')
    :and_then(function(a, b)
      return Op.always(b, a, 'C')
    end)
    :map(function(x, y, z)
      return x .. y .. z, x, z
    end)
    :wrap(function(joined, x, z)
      return joined .. ':' .. x .. ':' .. z, z
    end))

  assert_status(status, 'found')
  assert_eq(values.n, 2, 'multi-value arity survives and_then, map, and wrap')
  assert_eq(values[1], 'BAC:B:C')
  assert_eq(values[2], 'C')
end

local function test_deferred_map_and_and_then_after_rendezvous()
  do
    local rt = new_runtime()
    local ch = Rendezvous.new('deferred-map-rendezvous')
    local got
    rt:spawn_raw(function()
      got = rt:perform(ch:get_op():map(function(v)
        return v .. '!'
      end))
    end, 'deferred-map-receiver')
    rt:spawn_raw(function()
      rt:perform(ch:put_op('payload'))
    end, 'deferred-map-sender')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'payload!', 'map is applied after deferred rendezvous values are known')
  end

  do
    local rt = new_runtime()
    local ch = Rendezvous.new('deferred-and_then-rendezvous')
    local cell = Cell.new('unset', 'deferred-and_then-cell')
    local got
    rt:spawn_raw(function()
      got = rt:perform(ch:get_op():and_then(function(v)
        return cell:write_op(v):and_then(function()
          return cell:read_op():map(function(current)
            return current .. ':done'
          end)
        end)
      end))
    end, 'deferred-and_then-receiver')
    rt:spawn_raw(function()
      rt:perform(ch:put_op('message'))
    end, 'deferred-and_then-sender')
    assert_status(rt:run(), 'found')
    assert_eq(cell.value, 'message')
    assert_eq(got, 'message:done', 'and_then after rendezvous participates in the same transaction')
  end
end

local function test_choice_discards_loser_resource_state_even_when_loser_is_locally_possible()
  local rt = new_runtime({ choice_seed = 2 })
  local cell = Cell.new(0, 'choice-loser-resource-cell')
  local got

  local winner = Op.always('winner')
  local loser = cell:write_op(99):map(function()
    return 'loser'
  end)

  rt:spawn_raw(function()
    got = rt:perform(Op.choice(winner, loser))
  end, 'choice-loser-resource')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'winner', 'the replay seed selects the non-mutating occurrence')
  assert_eq(cell.value, 0, 'unselected choice branch does not commit its resource effects')
end

local function test_choice_blocked_branch_does_not_partially_commit_before_right_branch_wins()
  local rt = new_runtime()
  local cell = Cell.new(0, 'choice-blocked-left-cell')
  local ch = Rendezvous.new('choice-blocked-left-rendezvous')
  local got

  local blocked_left = cell:write_op(1):and_then(function()
    return ch:get_op()
  end)
  local right = cell:write_op(2):map(function()
    return 'right'
  end)

  rt:spawn_raw(function()
    got = rt:perform(Op.choice(blocked_left, right))
  end, 'choice-blocked-left')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'right')
  assert_eq(cell.value, 2, 'blocked losing branch does not leak earlier transactional writes')
end

local function test_together_is_parallel_not_sequential_for_cell_views()
  local rt = new_runtime()
  local cell = Cell.new(0, 'together-view-cell')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      cell:write_op(1),
      cell:read_op(),
    }))
  end, 'together-cell-views')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 1, 'together commits the selected write')
  assert_eq(rows[1][1], true)
  assert_eq(
    rows[2][1],
    0,
    'sibling lane in together sees the shared pre-transaction view, not a sequential write'
  )
end

local function test_together_or_else_prefers_internal_rendezvous_over_fallback()
  local ch = Rendezvous.new('together-or-else-internal')
  local status, values = one_perform(Op.together({
    ch:get_op():or_else(Op.always('fallback')),
    ch:put_op('internal-message'),
  }))

  assert_status(status, 'found')
  local rows = values[1]
  assert_eq(
    rows[1][1],
    'internal-message',
    'or_else primary may be satisfied by an internal rendezvous in together'
  )
  assert_eq(rows[2][1], true)
end

local function test_or_else_primary_rendezvous_beats_fallback_when_partner_exists()
  local rt = new_runtime()
  local ch = Rendezvous.new('or-else-external-primary')
  local cell = Cell.new(0, 'or-else-external-primary-cell')
  local got

  rt:spawn_raw(function()
    got = rt:perform(ch:get_op():or_else(cell:write_op(99):map(function()
      return 'fallback'
    end)))
  end, 'or-else-external-receiver')
  rt:spawn_raw(function()
    rt:perform(ch:put_op('from-sender'))
  end, 'or-else-external-sender')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'from-sender')
  assert_eq(cell.value, 0, 'fallback branch is not committed when primary rendezvous can commit')
end

local function test_or_else_blocked_primary_discards_partial_state_before_fallback()
  local rt = new_runtime()
  local ch = Rendezvous.new('or-else-blocked-primary-rendezvous')
  local cell = Cell.new(0, 'or-else-blocked-primary-cell')
  local got

  local primary = cell:write_op(1):and_then(function()
    return ch:get_op()
  end)
  local fallback = cell:write_op(2):map(function()
    return 'fallback'
  end)

  rt:spawn_raw(function()
    got = rt:perform(primary:or_else(fallback))
  end, 'or-else-blocked-primary')
  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(cell.value, 2, 'fallback commits without leaking the blocked primary write')
end

local function test_choice_backtracks_around_product_conflict()
  local rt = new_runtime()
  local cell = Cell.new(0, 'choice-product-conflict-cell')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      cell
        :write_op(1)
        :map(function()
          return 'write-1'
        end)
        :choice(Op.always('no-write')),
      cell:write_op(2),
    }))
  end, 'choice-product-conflict')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2, 'search backtracks from a locally possible branch that conflicts in the product')
  assert_eq(rows[1][1], 'no-write')
  assert_eq(rows[2][1], true)
end

local function test_guard_memo_survives_refresh_of_stale_frontier()
  local rt = new_runtime()
  local cell = Cell.new(0, 'guard-refresh-cell')
  local guard_calls = 0
  local a, b

  rt:spawn_raw(function()
    a = rt:perform(update_cell(cell, function(v)
      return v + 1
    end))
  end, 'guard-refresh-first-updater')

  rt:spawn_raw(function()
    b = rt:perform(Op.guard(function()
      guard_calls = guard_calls + 1
      return update_cell(cell, function(v)
        return v + 1
      end)
    end))
  end, 'guard-refresh-guarded-updater')

  assert_status(rt:run(), 'found')
  assert_eq(cell.value, 2)
  assert_eq(a, 1)
  assert_eq(b, 2)
  assert_eq(
    guard_calls,
    1,
    'refresh reuses the guarded expression for the same attempt rather than rerunning guard effects'
  )
end

local function test_multiple_wraps_run_in_order_after_discharge()
  local timeline = {}
  local rt = new_runtime({
    host = {
      test_tag = function()
        timeline[#timeline + 1] = 'discharge'
      end,
    },
  })
  local got

  rt:spawn_raw(function()
    got = rt:perform(Op.emit(TC.tag('multi-wrap'))
      :and_then(function()
        return Op.always('x')
      end)
      :wrap(function(v)
        timeline[#timeline + 1] = 'wrap1'
        return v .. '1'
      end)
      :wrap(function(v)
        timeline[#timeline + 1] = 'wrap2'
        return v .. '2'
      end))
    timeline[#timeline + 1] = 'resume'
  end, 'multi-wrap')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'x12')
  assert_eq(
    table.concat(timeline, ','),
    'discharge,wrap1,wrap2,resume',
    'multiple wraps run in order after discharge and before fibre continuation'
  )
end

local function test_wrap_may_perform_new_transaction_after_commit()
  local cell = Cell.new(0, 'wrap-nested-perform-cell')
  local timeline = {}
  local got
  local rt = new_runtime({
    host = {
      test_tag = function(tag)
        timeline[#timeline + 1] = 'discharge:' .. tag
      end,
    },
  })

  local outer = Op.emit(TC.tag('outer')):and_then(function()
    return cell:write_op(1):and_then(function()
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
  assert_eq(
    table.concat(timeline, ','),
    'discharge:outer,wrap-start,discharge:inner,wrap-end,resume',
    'wrap may perform a fresh transaction after the outer commit'
  )
end

local function test_wrap_failure_does_not_rollback_committed_resources()
  local cell = Cell.new(0, 'wrap-failure-cell')
  local rt = new_runtime()

  rt:spawn_raw(function()
    rt:perform(cell:write_op(5):and_then(function()
      return Op.always('x'):wrap(function()
        error('wrap boom')
      end)
    end))
  end, 'wrap-failure')

  local ok, err = pcall(function()
    return rt:run()
  end)
  assert_eq(ok, false, 'wrap failure is reported to the caller')
  assert_truthy(tostring(err):match('wrap boom'), 'wrap failure reports the original error')
  assert_eq(cell.value, 5, 'committed resource state is not rolled back by wrap failure')
end

local function test_product_lane_wraps_apply_inside_out_after_commit()
  local timeline = {}
  local rt = new_runtime({
    host = {
      test_tag = function(tag)
        timeline[#timeline + 1] = 'discharge:' .. tag
      end,
    },
  })
  local ch_a = Rendezvous.new('wrap-product-a')
  local ch_b = Rendezvous.new('wrap-product-b')
  local got, put_a, put_b

  rt:spawn_raw(function()
    got = rt:perform(Op.emit(TC.tag('outer')):and_then(function()
      return Op.each({
        ch_a:get_op():wrap(function(v)
          timeline[#timeline + 1] = 'wrap-a'
          local suffix = rt:perform(Op.emit(TC.tag('inner-a')):and_then(function()
            return Op.always('!')
          end))
          return v .. suffix
        end),
        ch_b:get_op():wrap(function(v)
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
    end))
    timeline[#timeline + 1] = 'resume'
  end, 'wrapped-product-receiver')

  rt:spawn_raw(function()
    put_a = rt:perform(ch_a:put_op('a'))
  end, 'wrapped-product-sender-a')
  rt:spawn_raw(function()
    put_b = rt:perform(ch_b:put_op('b'))
  end, 'wrapped-product-sender-b')

  assert_status(rt:run(), 'found')
  assert_eq(put_a, true)
  assert_eq(put_b, true)
  assert_eq(got[1][1], 'a!')
  assert_eq(got[2][1], 'b?')
  assert_eq(got.outer, true, 'outer wrap sees product after lane-local wraps')
  assert_eq(
    table.concat(timeline, ','),
    'discharge:outer,wrap-a,discharge:inner-a,wrap-b,discharge:inner-b,wrap-outer,resume',
    'lane wraps run left-to-right inside the outer wrap after commit'
  )
end

local function test_together_lane_wraps_apply_after_internal_rendezvous()
  local ch = Rendezvous.new('wrap-together-internal')
  local timeline = {}
  local status, values = one_perform(Op.together({
    ch:put_op('payload'):wrap(function(v)
      timeline[#timeline + 1] = 'put-wrap'
      return v and 'sent' or 'not-sent'
    end),
    ch:get_op():wrap(function(v)
      timeline[#timeline + 1] = 'get-wrap'
      return v .. ':got'
    end),
  }):wrap(function(rows)
    timeline[#timeline + 1] = 'outer-wrap'
    return rows
  end))

  assert_status(status, 'found')
  assert_eq(values[1][1][1], 'sent')
  assert_eq(values[1][2][1], 'payload:got')
  assert_eq(
    table.concat(timeline, ','),
    'put-wrap,get-wrap,outer-wrap',
    'lane wraps in together run after internal rendezvous resolution'
  )
end

local function test_map_and_and_then_reject_options_containing_wraps()
  local wrapped_product = Op.each({ Op.always('x'):wrap(function(v)
    return v
  end) })
  local ok_map = pcall(function()
    return wrapped_product:map(function(rows)
      return rows
    end)
  end)
  local ok_and_then = pcall(function()
    return wrapped_product:and_then(function()
      return Op.always('next')
    end)
  end)
  local ok_outer_wrap = pcall(function()
    return wrapped_product:wrap(function(rows)
      return rows
    end)
  end)

  assert_eq(ok_map, false, 'map cannot consume a product containing a post-commit wrap')
  assert_eq(ok_and_then, false, 'and_then cannot consume a product containing a post-commit wrap')
  assert_eq(ok_outer_wrap, true, 'outer wrap remains valid on a product containing lane-local wraps')
end

local function test_choice_normalises_nested_lists_and_choice_nodes()
  local nested =
    Op.choice(Op.never(), { Op.never(), { Op.always('that') } }, Op.choice(Op.never(), Op.always('your')))
  assert_eq(nested.kind, 'choice', 'normalised multi-way choice remains a choice')
  assert_eq(#nested.choices, 2, 'choice flattens arrays, nested choices, and drops empty choices')
  local status, values = one_perform(nested)
  assert_status(status, 'found')
  assert_truthy(
    values[1] == 'that' or values[1] == 'your',
    'unordered choice may select either viable normalised branch'
  )
end

local function test_choice_seed_replays_unordered_selection()
  local function select(seed)
    local status, values =
      one_perform(Op.choice(Op.always('left'), Op.always('right')), { choice_seed = seed })
    assert_status(status, 'found')
    return values[1]
  end

  local first = select(1)
  assert_eq(select(1), first, 'the same choice seed should replay the same traversal')
  assert_truthy(select(2) ~= first, 'different seeds should be able to select a different viable branch')
end

local function test_choice_rejects_sparse_or_named_tables()
  local ok_named = pcall(function()
    Op.choice({ left = Op.always('bad') })
  end)
  assert_eq(ok_named, false, 'plain choice should not accept named maps')

  local ok_sparse = pcall(function()
    Op.choice({ [1] = Op.always('first'), [3] = Op.always('third') })
  end)
  assert_eq(ok_sparse, false, 'plain choice should not accept sparse arrays')
end

local function test_each_and_together_require_dense_arrays_of_ops()
  local constructors = {
    { name = 'each', fn = Op.each },
    { name = 'together', fn = Op.together },
  }
  local invalid = {
    { value = 'not-an-array', description = 'a non-table value' },
    { value = { left = Op.always('bad') }, description = 'a named map' },
    {
      value = { [1] = Op.always('first'), [3] = Op.always('third') },
      description = 'a sparse array',
    },
    { value = { Op.always('good'), 'bad' }, description = 'a non-Op lane' },
  }

  for i = 1, #constructors do
    local constructor = constructors[i]
    for j = 1, #invalid do
      local case = invalid[j]
      local ok, err = pcall(constructor.fn, case.value)
      assert_eq(ok, false, constructor.name .. ' should reject ' .. case.description)
      assert_truthy(
        tostring(err):find(constructor.name .. ' expects a dense array of Op values', 1, true),
        constructor.name .. ' should report its dense Op-array contract'
      )
    end
  end
end

local function test_each_and_together_copy_their_validated_lanes()
  local each_lanes = { Op.always('a'), Op.always('b') }
  local together_lanes = { Op.always('x'), Op.always('y') }
  local each_op = Op.each(each_lanes)
  local together_op = Op.together(together_lanes)

  each_lanes[1] = 'mutated'
  together_lanes[2] = 'mutated'

  assert_truthy(Op.is_op(each_op.lanes[1]), 'each should retain its validated lane copy')
  assert_truthy(Op.is_op(together_op.lanes[2]), 'together should retain its validated lane copy')
end

local function test_named_choice_tags_the_winning_branch()
  local op = Op.named_choice({
    { 'left', Op.never() },
    { 'right', Op.always('value', 7) },
  })
  local status, values = one_perform(op)
  assert_status(status, 'found')
  assert_eq(values[1], 'right')
  assert_eq(values[2], 'value')
  assert_eq(values[3], 7)
end

local function test_named_each_returns_record_values_and_raw_rows()
  local op = Op.named_each({
    { 'a', Op.always('A') },
    { 'b', Op.always('B', 2) },
  })
  local status, values = one_perform(op)
  assert_status(status, 'found')
  local r = values[1]
  assert_eq(r.a, 'A')
  assert_truthy(type(r.b) == 'table' and r.b.n == 2, 'multi-valued named_each entry should keep its row pack')
  assert_eq(r.b[1], 'B')
  assert_eq(r.b[2], 2)
  assert_eq(r._rows.a[1], 'A')
end

local tests = {
  test_choice_normalises_nested_lists_and_choice_nodes,
  test_choice_seed_replays_unordered_selection,
  test_choice_rejects_sparse_or_named_tables,
  test_each_and_together_require_dense_arrays_of_ops,
  test_each_and_together_copy_their_validated_lanes,
  test_named_choice_tags_the_winning_branch,
  test_named_each_returns_record_values_and_raw_rows,
  test_canonical_algebra_vocabulary,
  test_always_and_never,
  test_multi_value_and_then_map_and_wrap_preserve_arity,
  test_deferred_map_and_and_then_after_rendezvous,
  test_map_and_and_then_are_transactional,
  test_and_then_is_all_or_nothing,
  test_choice_selects_one_world_and_discards_loser,
  test_choice_discards_loser_resource_state_even_when_loser_is_locally_possible,
  test_choice_blocked_branch_does_not_partially_commit_before_right_branch_wins,
  test_or_else_preference_and_fallback,
  test_or_else_primary_absence_is_checked_across_other_participants,
  test_together_or_else_prefers_internal_rendezvous_over_fallback,
  test_or_else_primary_rendezvous_beats_fallback_when_partner_exists,
  test_or_else_blocked_primary_discards_partial_state_before_fallback,
  test_or_else_retries_stale_primary_instead_of_committing_fallback,
  test_guard_is_delayed_and_participates_in_search,
  test_guard_memo_survives_refresh_of_stale_frontier,
  test_wrap_is_post_commit_and_not_transactional_sequence,
  test_multiple_wraps_run_in_order_after_discharge,
  test_wrap_may_perform_new_transaction_after_commit,
  test_wrap_failure_does_not_rollback_committed_resources,
  test_product_lane_wraps_apply_inside_out_after_commit,
  test_together_lane_wraps_apply_after_internal_rendezvous,
  test_map_and_and_then_reject_options_containing_wraps,
  test_each_and_together_internal_rendezvous_topology,
  test_together_is_parallel_not_sequential_for_cell_views,
  test_choice_backtracks_around_product_conflict,
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
--   fibers.resource.rendezvous
--   fibers.resource.cell

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

local Op = require('fibers.op')
local Runtime = require('fibers.runtime')
local Rendezvous = require('fibers.resource.rendezvous')
local Cell = require('fibers.resource.cell')
local TC = require('tests.support.effect_helpers')

local function new_runtime(opts)
  opts = opts or {}
  local tags = {}
  local host = opts.host or {}
  local previous = host.test_tag
  host.test_tag = function(tag, payload)
    tags[#tags + 1] = tag
    if previous then
      return previous(tag, payload)
    end
  end
  opts.host = host
  local rt = Runtime.new(opts)
  rt._test_tags = tags
  return rt
end

local function update_cell(cell, fn)
  return cell:read_op():and_then(function(old)
    local new = fn(old)
    return cell:write_op(new):map(function()
      return new, old
    end)
  end)
end

local pack_ = table.pack or function(...)
  return { n = select('#', ...), ... }
end

local unpack_ = table.unpack or unpack

local function fail(msg)
  error(msg, 2)
end

local function tostring_value(v)
  if type(v) == 'table' then
    return '<table>'
  end
  return tostring(v)
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail(
      (msg or 'assert_eq failed')
        .. ': expected '
        .. tostring_value(expected)
        .. ', got '
        .. tostring_value(actual)
    )
  end
end

local function assert_truthy(value, msg)
  if not value then
    fail(msg or 'expected truthy value')
  end
end

local function assert_falsy(value, msg)
  if value then
    fail((msg or 'expected falsy value') .. ': got ' .. tostring_value(value))
  end
end

local function assert_status(status, tag, msg)
  if not status or status.tag ~= tag then
    fail(
      (msg or 'status mismatch')
        .. ': expected '
        .. tostring(tag)
        .. ', got '
        .. tostring(status and status.tag)
        .. ' ('
        .. tostring(status and status.reason)
        .. ')'
    )
  end
  return status.value
end

local function assert_uncommitted_status(status, msg)
  local tag = status and status.tag
  if tag ~= 'quiescent' and tag ~= 'conflict' and tag ~= 'reject_candidate' and tag ~= 'pending' then
    fail((msg or 'expected uncommitted status') .. ': got ' .. tostring(tag))
  end
end

local function one_perform(op, opts)
  local rt = new_runtime(opts or {})
  local values = { n = 0 }
  rt:spawn_raw(function()
    values = pack_(rt:perform(op))
  end, 'one-perform')
  local status = rt:run()
  return status, values, rt
end

local function transaction_tags(rt)
  return table.concat(rt._test_tags or {}, ',')
end

local function obligation_entries(_rt, _kind)
  return {}
end

local function assert_set_eq(actual, expected, msg)
  if #actual ~= #expected then
    fail((msg or 'set length mismatch') .. ': expected ' .. #expected .. ', got ' .. #actual)
  end
  local seen = {}
  for i = 1, #actual do
    seen[tostring(actual[i])] = (seen[tostring(actual[i])] or 0) + 1
  end
  for i = 1, #expected do
    local k = tostring(expected[i])
    if not seen[k] or seen[k] == 0 then
      fail((msg or 'set mismatch') .. ': missing ' .. k)
    end
    seen[k] = seen[k] - 1
  end
  for k, n in pairs(seen) do
    if n ~= 0 then
      fail((msg or 'set mismatch') .. ': unexpected ' .. k)
    end
  end
end

-- A guard is a pre-attempt constructor, not a permanent global memo for the
-- scope of an expression value. A reusable first-class transaction expression
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

local function test_or_else_primary_second_candidate_beats_fallback()
  local rt = new_runtime()
  local cell = Cell.new('init', 'primary-second-candidate-cell')
  local bad = Rendezvous.new('primary-second-bad')
  local good = Rendezvous.new('primary-second-good')
  local got, bad_sender, good_sender

  local bad_primary = bad:get_op():and_then(function(v)
    return cell:write_op('bad'):and_then(function()
      return Op.always('bad:' .. tostring(v))
    end)
  end)
  local good_primary = good:get_op():and_then(function(v)
    return cell:write_op('good'):and_then(function()
      return Op.always('good:' .. tostring(v))
    end)
  end)
  local primary = Op.choice(bad_primary, good_primary)
  local fallback = Op.emit(TC.tag('bad.fallback')):and_then(function()
    return cell:write_op('fallback'):and_then(function()
      return Op.always('fallback')
    end)
  end)

  rt:spawn_raw(function()
    got = rt:perform(primary:or_else(fallback))
  end, 'receiver')
  rt:spawn_raw(function()
    bad_sender = rt:perform(Op.each({ bad:put_op('payload'), cell:write_op('conflict') }))
  end, 'bad-conflicting-sender')
  rt:spawn_raw(function()
    good_sender = rt:perform(good:put_op('payload'))
  end, 'good-sender')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'good:payload', 'second primary candidate commits before fallback')
  assert_eq(good_sender, true)
  assert_falsy(bad_sender, 'conflicting primary partner does not commit')
  assert_eq(cell.value, 'good')
  assert_eq(transaction_tags(rt), '', 'fallback effect is not discharged')
end

-- The primary can become available only if another participant backtracks to a
-- non-first branch. Fallback must wait for that global possibility.
local function test_or_else_primary_needs_partner_backtracking()
  local rt = new_runtime()
  local wanted = Rendezvous.new('partner-backtrack-wanted')
  local dead = Rendezvous.new('partner-backtrack-dead')
  local receiver, partner

  rt:spawn_raw(function()
    receiver = rt:perform(wanted
      :get_op()
      :map(function(v)
        return 'primary:' .. tostring(v)
      end)
      :or_else(Op.emit(TC.tag('partner.backtrack.fallback')):and_then(function()
        return Op.always('fallback')
      end)))
  end, 'receiver')

  rt:spawn_raw(function()
    partner = rt:perform(Op.choice(dead:put_op('dead'), wanted:put_op('ok')))
  end, 'partner')

  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:ok', 'partner backtracking makes primary globally available')
  assert_eq(partner, true)
  assert_eq(transaction_tags(rt), '', 'fallback does not discharge')
end

-- Rendezvous and resource compatibility must be solved together.
local function test_or_else_primary_resource_conflict_backtracks_partner_branch()
  local rt = new_runtime()
  local cell = Cell.new(0, 'primary-resource-conflict-cell')
  local ch = Rendezvous.new('primary-resource-conflict-rendezvous')
  local receiver, partner

  local primary = ch:get_op():and_then(function(v)
    return cell:write_op(1):and_then(function()
      return Op.always('primary:' .. tostring(v))
    end)
  end)
  local fallback = Op.emit(TC.tag('resource.conflict.fallback')):and_then(function()
    return Op.always('fallback')
  end)

  rt:spawn_raw(function()
    receiver = rt:perform(primary:or_else(fallback))
  end, 'receiver')
  rt:spawn_raw(function()
    partner = rt:perform(
      Op.choice(
        Op.each({ ch:put_op('bad'), cell:write_op(2) }),
        Op.each({ ch:put_op('good'), cell:write_op(1) })
      )
    )
  end, 'partner')

  assert_status(rt:run(), 'found')
  assert_eq(receiver, 'primary:good', 'runtime backtracks through a conflicting partner branch')
  assert_truthy(partner ~= nil, 'compatible partner branch commits')
  assert_eq(cell.value, 1)
  assert_eq(transaction_tags(rt), '', 'fallback effect is not discharged')
end

local function test_or_else_absent_primary_discards_tentative_writes()
  local rt = new_runtime()
  local cell = Cell.new('initial', 'absent-primary-discards-writes-cell')
  local ch = Rendezvous.new('absent-primary-discards-writes-rendezvous')
  local got

  local primary = cell:write_op('primary'):and_then(function()
    return ch:get_op()
  end)
  local fallback = cell:write_op('fallback'):and_then(function()
    return Op.always('fallback')
  end)

  rt:spawn_raw(function()
    got = rt:perform(primary:or_else(fallback))
  end, 'receiver')

  assert_status(rt:run(), 'found')
  assert_eq(got, 'fallback')
  assert_eq(cell.value, 'fallback', 'tentative write in absent primary is discarded')
end

local function test_nested_or_else_uses_nearest_available_world()
  do
    local rt = new_runtime()
    local ch = Rendezvous.new('nested-or-else-primary')
    local got, sender
    local op = ch:get_op()
      :map(function(v)
        return 'primary:' .. v
      end)
      :or_else(Op.always('inner'))
      :or_else(Op.always('outer'))
    rt:spawn_raw(function()
      got = rt:perform(op)
    end, 'receiver')
    rt:spawn_raw(function()
      sender = rt:perform(ch:put_op('ok'))
    end, 'sender')
    assert_status(rt:run(), 'found')
    assert_eq(got, 'primary:ok')
    assert_eq(sender, true)
  end

  do
    local status, values = one_perform(
      Rendezvous.new('nested-or-else-absent'):get_op():or_else(Op.always('inner')):or_else(Op.always('outer'))
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

local function test_together_lane_and_then_after_internal_rendezvous_is_lane_local()
  local rt = new_runtime()
  local ch = Rendezvous.new('together-lane-and_then-internal')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ch:get_op():and_then(function(v)
        return Op.always('got:' .. v)
      end),
      ch:put_op('payload'),
    }))
  end, 'together-lane-and_then-internal-root')

  assert_status(rt:run(), 'found')
  assert_truthy(rows and rows._fibers_rows, 'together returns rows')
  assert_eq(rows[1][1], 'got:payload', 'lane-local and_then sees received payload, not product rows')
  assert_eq(rows[2][1], true, 'send lane commits')
end

local function test_together_lane_and_then_returned_wrap_is_lane_local()
  local rt = new_runtime()
  local ch = Rendezvous.new('together-lane-and_then-wrap')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ch:get_op():and_then(function(v)
        return Op.always(v):wrap(function(x)
          return 'wrapped:' .. x
        end)
      end),
      ch:put_op('payload'),
    }))
  end, 'together-lane-and_then-wrap-root')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'wrapped:payload', 'wrap returned by lane-local and_then applies to that lane only')
  assert_eq(rows[2][1], true, 'send lane is not wrapped')
end

local function test_together_lane_and_then_rejection_after_internal_rendezvous_backtracks()
  local rt = new_runtime({ quiet_deadlock = true })
  local ch = Rendezvous.new('together-lane-and_then-reject')
  local rows

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      ch:get_op():and_then(function(v)
        if v == 'wanted' then
          return Op.always(v)
        end
        return Op.never()
      end),
      ch:put_op('wrong'),
    }))
  end, 'together-lane-and_then-reject-root')

  local status = rt:run()
  assert_uncommitted_status(status, 'rejected lane-local and_then should make the interacting world absent')
  assert_eq(rows, nil, 'rejected world does not resume the participant')
end

local function test_together_lane_and_then_after_internal_rendezvous_can_require_external_rendezvous()
  local rt = new_runtime()
  local internal = Rendezvous.new('together-lane-and_then-internal-then-external-internal')
  local external = Rendezvous.new('together-lane-and_then-internal-then-external-external')
  local rows, sender

  rt:spawn_raw(function()
    rows = rt:perform(Op.together({
      internal:get_op():and_then(function(v)
        return external:get_op():map(function(w)
          return tostring(v) .. ':' .. tostring(w)
        end)
      end),
      internal:put_op('inside'),
    }))
  end, 'together-lane-and_then-internal-then-external-root')

  rt:spawn_raw(function()
    sender = rt:perform(external:put_op('outside'))
  end, 'together-lane-and_then-internal-then-external-sender')

  assert_status(rt:run(), 'found')
  assert_eq(
    rows[1][1],
    'inside:outside',
    'lane and_then may introduce a further external rendezvous before the enclosing together operation commits'
  )
  assert_eq(rows[2][1], true, 'internal send lane commits')
  assert_eq(sender, true, 'external partner commits in the same selected world')
end

local function test_nested_product_deferred_and_then_preserves_inner_lane_locality()
  local ch = Rendezvous.new('nested-product-lane-and_then')
  local status, values = one_perform(Op.together({
    Op.together({
      ch:get_op():and_then(function(v)
        return Op.always('inner:' .. tostring(v))
      end),
      ch:put_op('payload'),
    }),
    Op.always('outer-side'),
  }))

  assert_status(status, 'found')
  local outer_rows = values[1]
  local inner_rows = outer_rows[1][1]
  assert_truthy(inner_rows and inner_rows._fibers_rows, 'nested lane in together returns its own row table')
  assert_eq(inner_rows[1][1], 'inner:payload', 'deferred and_then rewrites the nested receive lane only')
  assert_eq(inner_rows[2][1], true, 'nested send lane is preserved')
  assert_eq(outer_rows[2][1], 'outer-side', 'outer sibling lane is preserved')
end

local function test_each_lane_and_then_after_external_rendezvous_is_lane_local()
  local rt = new_runtime()
  local ch = Rendezvous.new('each-lane-and_then-external')
  local rows, sender

  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      ch:get_op():and_then(function(v)
        return Op.always('got:' .. tostring(v))
      end),
      Op.always('side'),
    }))
  end, 'each-lane-and_then-external-root')

  rt:spawn_raw(function()
    sender = rt:perform(ch:put_op('payload'))
  end, 'each-lane-and_then-external-sender')

  assert_status(rt:run(), 'found')
  assert_eq(
    rows[1][1],
    'got:payload',
    'each lane and_then sees the value supplied by an external participant'
  )
  assert_eq(rows[2][1], 'side', 'each sibling lane is preserved')
  assert_eq(sender, true, 'external rendezvous partner commits')
end

local function test_multiple_deferred_lane_and_thens_rewrite_only_their_own_lanes()
  local rt = new_runtime()
  local a = Rendezvous.new('multiple-lane-and_then-a')
  local b = Rendezvous.new('multiple-lane-and_then-b')
  local rows, send_a, send_b

  rt:spawn_raw(function()
    rows = rt:perform(Op.each({
      a:get_op():and_then(function(v)
        return Op.always('A:' .. tostring(v))
      end),
      b:get_op():and_then(function(v)
        return Op.always('B:' .. tostring(v))
      end),
    }))
  end, 'multiple-lane-and_thens-root')

  rt:spawn_raw(function()
    send_a = rt:perform(a:put_op('one'))
  end, 'multiple-lane-and_thens-sender-a')
  rt:spawn_raw(function()
    send_b = rt:perform(b:put_op('two'))
  end, 'multiple-lane-and_thens-sender-b')

  assert_status(rt:run(), 'found')
  assert_eq(rows[1][1], 'A:one', 'first deferred and_then rewrites only lane one')
  assert_eq(rows[2][1], 'B:two', 'second deferred and_then rewrites only lane two')
  assert_eq(send_a, true)
  assert_eq(send_b, true)
end

local function test_lane_and_then_returning_emit_contributes_to_selected_world()
  local ch = Rendezvous.new('lane-and_then-returning-emit')
  local status, values, rt = one_perform(Op.together({
    ch:get_op():and_then(function(v)
      return Op.emit(TC.tag('lane.emit.' .. tostring(v))):and_then(function()
        return Op.always('got:' .. tostring(v))
      end)
    end),
    ch:put_op('payload'),
  }))

  assert_status(status, 'found')
  local rows = values[1]
  assert_eq(rows[1][1], 'got:payload')
  assert_eq(rows[2][1], true)
  assert_eq(
    transaction_tags(rt),
    'lane.emit.payload',
    'effect returned by a lane-local and_then is part of the selected committed world'
  )
end

local function test_together_internal_and_external_rendezvous_must_all_close()
  local rt = new_runtime()
  local internal = Rendezvous.new('together-subtle-internal')
  local external = Rendezvous.new('together-subtle-external')
  local a, b

  local op = Op.together({
    internal:put_op('inside'),
    internal:get_op(),
    external:get_op(),
  }):map(function(rows)
    return tostring(rows[2][1]) .. '+' .. tostring(rows[3][1])
  end)

  rt:spawn_raw(function()
    a = rt:perform(op)
  end, 'together-root')
  rt:spawn_raw(function()
    b = rt:perform(external:put_op('outside'))
  end, 'external-partner')

  assert_status(rt:run(), 'found')
  assert_eq(a, 'inside+outside', 'together root commits only after internal and external rendezvous close')
  assert_eq(b, true)
end

local function test_each_does_not_allow_internal_rendezvous_even_nested()
  local ch = Rendezvous.new('each-nested-no-internal')
  local status = one_perform(
    Op.each({
      Op.together({ Op.always('irrelevant') }),
      ch:put_op('x'),
      ch:get_op(),
    }),
    { quiet_deadlock = true }
  )
  assert_uncommitted_status(status, 'each still does not permit internal rendezvous between its own lanes')
end

local function test_triple_swap_with_decoy_does_not_greedily_partially_commit()
  local rt = new_runtime()
  local ab = Rendezvous.new('triple-decoy-ab')
  local bc = Rendezvous.new('triple-decoy-bc')
  local ca = Rendezvous.new('triple-decoy-ca')
  local a, b, c, decoy

  rt:spawn_raw(function()
    a = rt:perform(Op.each({ ab:put_op('A'), ca:get_op() }):map(function(rows)
      return rows[2][1]
    end))
  end, 'A')
  rt:spawn_raw(function()
    b = rt:perform(Op.each({ bc:put_op('B'), ab:get_op() }):map(function(rows)
      return rows[2][1]
    end))
  end, 'B')
  rt:spawn_raw(function()
    c = rt:perform(Op.each({ ca:put_op('C'), bc:get_op() }):map(function(rows)
      return rows[2][1]
    end))
  end, 'C')
  rt:spawn_raw(function()
    decoy = rt:perform(ab:get_op())
  end, 'decoy')

  assert_status(rt:run(), 'found')
  assert_eq(a, 'C')
  assert_eq(b, 'A')
  assert_eq(c, 'B')
  assert_eq(decoy, nil, 'decoy partial communication is not committed')
end

local function test_dependent_cell_updates_are_serialisable_under_observation()
  local rt = new_runtime()
  local cell = Cell.new(0, 'dependent-observation-cell')
  local returns = {}

  local function op()
    return cell:read_op():and_then(function(old)
      return cell:write_op(old + 1):and_then(function()
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

local tests = {
  { 'guard is per-attempt, not permanent memo', test_guard_is_per_attempt_not_permanent_memo },
  {
    'or_else primary second candidate beats fallback',
    test_or_else_primary_second_candidate_beats_fallback,
  },
  { 'or_else primary needs partner backtracking', test_or_else_primary_needs_partner_backtracking },
  {
    'or_else primary resource conflict backtracks partner branch',
    test_or_else_primary_resource_conflict_backtracks_partner_branch,
  },
  {
    'or_else absent primary discards tentative writes',
    test_or_else_absent_primary_discards_tentative_writes,
  },
  {
    'nested or_else uses nearest available world',
    test_nested_or_else_uses_nearest_available_world,
  },
  {
    'lane and_then in together after internal rendezvous is lane local',
    test_together_lane_and_then_after_internal_rendezvous_is_lane_local,
  },
  {
    'a wrap returned by lane and_then in together is lane local',
    test_together_lane_and_then_returned_wrap_is_lane_local,
  },
  {
    'lane and_then rejection in together backtracks after internal rendezvous',
    test_together_lane_and_then_rejection_after_internal_rendezvous_backtracks,
  },
  {
    'lane and_then in together can require an external rendezvous',
    test_together_lane_and_then_after_internal_rendezvous_can_require_external_rendezvous,
  },
  {
    'nested product deferred and_then preserves inner lane locality',
    test_nested_product_deferred_and_then_preserves_inner_lane_locality,
  },
  {
    'each lane and_then after external rendezvous is lane local without internal closure',
    test_each_lane_and_then_after_external_rendezvous_is_lane_local,
  },
  {
    'multiple deferred lane and_thens rewrite only their own lanes',
    test_multiple_deferred_lane_and_thens_rewrite_only_their_own_lanes,
  },
  {
    'lane and_then returning emit contributes to selected world',
    test_lane_and_then_returning_emit_contributes_to_selected_world,
  },
  {
    'internal and external rendezvous in together must all close',
    test_together_internal_and_external_rendezvous_must_all_close,
  },
  {
    'each does not allow internal rendezvous even when nested',
    test_each_does_not_allow_internal_rendezvous_even_nested,
  },
  {
    'triple swap with decoy does not partially commit',
    test_triple_swap_with_decoy_does_not_greedily_partially_commit,
  },
  {
    'dependent cell updates are serialisable under observation',
    test_dependent_cell_updates_are_serialisable_under_observation,
  },
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

-- Public constructors reject malformed callbacks and operands immediately.
do
  assert(not pcall(Op.guard, 'not-a-function'))
  local base = Op.always('x')
  assert(not pcall(function()
    return base:map('not-a-function')
  end))
  assert(not pcall(function()
    return base:and_then('not-a-function')
  end))
  assert(not pcall(function()
    return base:wrap('not-a-function')
  end))
  assert(not pcall(function()
    return base:or_else('not-an-op')
  end))
end

-- Named map forms use string keys for portable deterministic ordering. Ordered
-- entries remain available when a non-string label is deliberately required.
do
  assert(not pcall(function()
    return Op.named_choice({ [1] = Op.always('numeric-map-key') })
  end))
  local label, value = fibers.run(function()
    return fibers.perform(Op.named_choice({ { 1, Op.always('ordered') } }))
  end)
  assert_eq(label, 1)
  assert_eq(value, 'ordered')
end

-- Small public always-options are fresh opaque occurrences. Unsupported mutation
-- of one occurrence must not alter later options returned by the library.
do
  local first = Op.always(true)
  local second = Op.always(true)
  local empty_first = Op.always()
  local empty_second = Op.always()
  assert(first ~= second)
  assert(empty_first ~= empty_second)
  assert(empty_first.vals ~= empty_second.vals)
  first.kind = 'choice'
  empty_first.vals.n = 1
  empty_first.vals[1] = 'mutated'
  local value = fibers.run(function()
    return fibers.perform(second)
  end)
  assert_eq(value, true)
  local count = fibers.run(function()
    local values = { n = 0 }
    values.n = select('#', fibers.perform(empty_second))
    return values.n
  end)
  assert_eq(count, 0)
end

print('tests/test_op.lua: ok')
