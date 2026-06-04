package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

return function()
  local Op = require('et.op')
  local Runtime = require('et.runtime')
  local Cell = require('et.resources.cell')
  local Channel = require('et.resources.channel')

  local function assert_eq(actual, expected, msg)
    if actual ~= expected then
      error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
  end

  local function assert_status(x, tag, msg)
    if not x or x.tag ~= tag then
      error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2)
    end
    return x.value
  end

  local function run_capture(op, opts)
    local logs = {}
    opts = opts or {}
    local rt = Runtime.new({
      quiet_deadlock = opts.quiet_deadlock,
      on_consequence = function(log) logs[#logs + 1] = log end,
    })
    local a, b, c
    rt:spawn(function()
      a, b, c = rt:perform(op)
    end, 'capture')
    local status = rt:run()
    return { status = status, a = a, b = b, c = c, runtime = rt, logs = logs }
  end

  local function test_map_identity_and_composition()
    local base = Op.always(10)
    local lhs = run_capture(base:map(function(x) return x end))
    local rhs = run_capture(base)
    assert_status(lhs.status, 'found')
    assert_status(rhs.status, 'found')
    assert_eq(lhs.a, rhs.a, 'map id preserves result')

    local composed = run_capture(base:map(function(x) return x + 1 end):map(function(x) return x * 2 end))
    local fused = run_capture(base:map(function(x) return (x + 1) * 2 end))
    assert_status(composed.status, 'found')
    assert_status(fused.status, 'found')
    assert_eq(composed.a, fused.a, 'map composition fuses')
  end

  local function test_bind_identity_laws()
    local left = run_capture(Op.always(4):and_then(function(x) return Op.always(x + 7) end))
    local direct = run_capture(Op.always(11))
    assert_status(left.status, 'found')
    assert_status(direct.status, 'found')
    assert_eq(left.a, direct.a, 'left identity: always x >>= f == f x')

    local tx = Op.always('x', nil, 'z')
    local right = run_capture(tx:and_then(function(a, b, c)
      assert_eq(a, 'x')
      assert_eq(b, nil)
      assert_eq(c, 'z')
      return Op.always(a, b, c)
    end))
    assert_status(right.status, 'found')
    assert_eq(right.a, 'x', 'bind passes first value')
    assert_eq(right.b, nil, 'bind preserves nil row slot')
    assert_eq(right.c, 'z', 'bind passes later value')
  end

  local function test_choice_and_or_else_discard_losing_worlds()
    local left_dead = run_capture(
      Op.never():choice(Op.emit({ tag = 'right' }):and_then(function() return Op.always('right') end))
    )
    assert_status(left_dead.status, 'found')
    assert_eq(left_dead.a, 'right')
    assert_eq(#left_dead.logs, 1, 'selected choice publishes one log')
    assert_eq(#left_dead.logs[1].transaction, 1, 'selected choice publishes selected consequence')
    assert_eq(left_dead.logs[1].transaction[1].tag, 'right')

    local fallback = run_capture(
      Op.never():or_else(Op.emit({ tag = 'fallback' }):and_then(function() return Op.always('fallback') end))
    )
    assert_status(fallback.status, 'found')
    assert_eq(fallback.a, 'fallback')
    assert_eq(fallback.logs[1].transaction[1].tag, 'fallback', 'or_else publishes only fallback when primary absent')

    local c = Cell.new(0, 'law-or-else-primary')
    local rt = Runtime.new({ quiet_deadlock = true })
    local a, b
    rt:spawn(function() a = rt:perform(c:update_op(Op, function(v) return v + 1 end)) end, 'competing-update')
    rt:spawn(function()
      b = rt:perform(
        c:update_op(Op, function(v) return v + 1 end)
          :map(function() return 'primary' end)
          :or_else(Op.always('fallback'))
      )
    end, 'fallback-not-stale')
    assert_status(rt:run(), 'found')
    assert_eq(a, 1)
    assert_eq(b, 'primary', 'stale primary is retried and does not justify fallback')
    assert_eq(c.value, 2)
  end

  local function test_tensor_all_rendezvous_laws()
    local ch1 = Channel.new('law-tensor-rv')
    local tensor = run_capture(Op.tensor({ ch1:put_op(Op, 'payload'), ch1:get_op(Op) }))
    assert_status(tensor.status, 'found')
    assert_eq(tensor.a[1][1], true, 'tensor permits internal send')
    assert_eq(tensor.a[2][1], 'payload', 'tensor permits internal receive')

    local ch2 = Channel.new('law-all-forbid-rv')
    local all = run_capture(Op.all({ ch2:put_op(Op, 'payload'), ch2:get_op(Op) }), { quiet_deadlock = true })
    assert_eq(all.status.tag, 'absent', 'all forbids sibling internal rendezvous')

    local ch3 = Channel.new('law-all-inner-tensor-rv')
    local nested = run_capture(Op.all({ Op.tensor({ ch3:put_op(Op, 'payload'), ch3:get_op(Op) }) }))
    assert_status(nested.status, 'found')
    assert_eq(nested.a[1][1][1][1], true, 'all permits rendezvous inside nested tensor lane')
    assert_eq(nested.a[1][1][2][1], 'payload')
  end

  local function test_wrap_is_continuation_not_consequence()
    local events = {}
    local rt = Runtime.new({ on_consequence = function(log)
      events[#events + 1] = 'publish'
      assert_eq(log.transaction[1].tag, 'tx')
    end })
    local result
    rt:spawn(function()
      result = rt:perform(Op.emit({ tag = 'tx' }):and_then(function()
        return Op.always('value'):wrap(function(x)
          events[#events + 1] = 'wrap'
          return x .. '-wrapped'
        end)
      end))
      events[#events + 1] = 'resume'
    end, 'wrap-law')
    assert_status(rt:run(), 'found')
    assert_eq(result, 'value-wrapped')
    assert_eq(events[1], 'publish', 'consequence publication precedes wrap')
    assert_eq(events[2], 'wrap', 'wrap runs as participant continuation')
    assert_eq(events[3], 'resume')
  end

  test_map_identity_and_composition()
  test_bind_identity_laws()
  test_choice_and_or_else_discard_losing_worlds()
  test_tensor_all_rendezvous_laws()
  test_wrap_is_continuation_not_consequence()
  print('algebraic law matrix: ok')
end
