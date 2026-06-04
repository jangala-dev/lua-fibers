package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

return function()
  do
    local _case = (function()
      package.path = table.concat({
        './?.lua', './?/init.lua', './?/?.lua',
        package.path,
      }, ';')
      
      local Result = require('et.kernel').Status
      local Phase = require('et.kernel').Phase
      local Op = require('et.op')
      local View = require('et.machine.frontier').View
      local Frontier = require('et.machine.frontier').Frontier
      local Cell = require('et.resources.cell')
      local Util = require('et.kernel').Util
      local Link = require('et.protocol').Link
      
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
      
      local function in_search(fn)
        return Phase.with('search', fn)
      end
      
      local function expand(op, attempt, view)
        return in_search(function(token)
          return Frontier.expand(op, attempt or { id = 'attempt' }, view, token)
        end)
      end
      
      local function probe(frontier, view)
        return in_search(function(token)
          return frontier:probe(view, token)
        end)
      end
      
      local function refresh(frontier, view)
        return in_search(function(token)
          return frontier:refresh(view, token)
        end)
      end
      
      local function first_frame(op, view)
        local f = assert_status(expand(op, { id = 'attempt' }, view), 'found', 'expand')
        local frames = assert_status(probe(f, view), 'found', 'probe')
        return frames[1], f
      end
      
      local function test_always_never()
        local view = View.open('pure')
        local frame = first_frame(Op.always(1, nil, 3), view)
        assert_eq(frame.values.n, 3, 'always preserves arity')
        local a, b, c = Util.unpack(frame.values)
        assert_eq(a, 1)
        assert_eq(b, nil)
        assert_eq(c, 3)
      
        local f = assert_status(expand(Op.never(), { id = 'never-attempt' }, view), 'found')
        assert_status(probe(f, view), 'absent', 'never probe')
      end
      
      local function test_bind_map()
        local view = View.open('bind-map')
        local op = Op.always(2)
          :map(function(x) return x + 3 end)
          :and_then(function(x) return Op.always(x * 10) end)
        local frame = first_frame(op, view)
        assert_eq(Util.unpack(frame.values), 50)
      end
      
      local function test_access_sequence()
        local c = Cell.new(0, 'c')
        local view = View.open('access')
        local op = c:update_op(Op, function(v) return v + 1 end)
          :and_then(function(updated)
            return c:get_op(Op):map(function(read_back)
              return updated, read_back
            end)
          end)
        local frame = first_frame(op, view)
        local updated, read_back = Util.unpack(frame.values)
        assert_eq(updated, 1)
        assert_eq(read_back, 1)
        assert_eq(c.value, 0, 'expansion is speculative and must not mutate resource')
        assert_eq(frame.evidence.resources.by_resource[c].value, 1, 'fragment records tentative value')
        assert_eq(frame.evidence.dependencies.by_resource[c], 0, 'resource access records frame-local dependency')
      end
      
      local function test_emit_and_wrap()
        local view = View.open('emit-wrap')
        local marker = { tag = 'publish', value = 7 }
        local wrapper = function(x) return x + 1 end
        local op = Op.emit(marker):and_then(function()
          return Op.always(41):wrap(wrapper)
        end)
      
        marker.value = 99
        local frame = first_frame(op, view)
        assert_eq(Util.unpack(frame.values), 41)
        assert_eq(#frame.evidence.consequences.transaction, 1, 'emit adds transaction consequence')
        assert_eq(frame.evidence.consequences.transaction[1].value, 7, 'emit consequence is copied at construction/expansion')
        frame.evidence.consequences.transaction[1].value = 100
        local frame_again = first_frame(op, View.open('emit-wrap-again'))
        assert_eq(frame_again.evidence.consequences.transaction[1].value, 7, 'frontier evidence receives copied consequence descriptors')
        assert_eq(#frame.evidence.post_programs, 1, 'wrap adds post-commit program')
        assert_eq(frame.evidence.post_programs[1], wrapper)
      end
      
      local function test_boundary_blocks_transactional_sequence()
        local ok, err = pcall(function()
          return Op.always(1):wrap(function(x) return x end):and_then(function(x) return Op.always(x) end)
        end)
        if ok then error('expected wrap boundary to reject transactional and_then', 2) end
        assert(tostring(err):match('sequence after wrap boundary'), err)
      end
      
      local function test_stale_frontier_cannot_be_probed()
        local c = Cell.new(10, 'stale-cell')
        local view1 = View.open('before-change')
        local f = assert_status(expand(c:get_op(Op), { id = 'attempt-stale' }, view1), 'found')
        assert_status(probe(f, view1), 'found')
      
        c:force_set(20)
      
        local stale = probe(f, view1)
        assert_status(stale, 'stale', 'old frontier must not be probed after resource version changes')
        assert_eq(stale.resources[1], c, 'stale result names changed resource')
      end
      
      local function test_refresh_produces_new_frontier_under_new_view()
        local c = Cell.new(3, 'refresh-cell')
        local view1 = View.open('refresh-1')
        local attempt = { id = 'attempt-refresh' }
        local f1 = assert_status(expand(c:get_op(Op), attempt, view1), 'found')
        local frame1 = assert_status(probe(f1, view1), 'found')[1]
        assert_eq(Util.unpack(frame1.values), 3, 'raw frontier get returns proof-time value')
      
        c:force_set(9)
        local view2 = View.open('refresh-2')
        assert_status(probe(f1, view2), 'stale', 'old frontier must not be probed under new view')
      
        local f2 = assert_status(refresh(f1, view2), 'found', 'refresh')
        assert(f2 ~= f1, 'refresh returns a new frontier certificate')
        assert_eq(f2.attempt, f1.attempt, 'refresh preserves live attempt identity')
        assert_eq(f2.view_id, view2.id, 'refresh uses new view')
        local frame2 = assert_status(probe(f2, view2), 'found')[1]
        assert_eq(Util.unpack(frame2.values), 9, 'refreshed frontier get returns fresh proof-time value')
      end
      
      local function test_view_is_lazy_and_version_recording()
        local c = Cell.new(1, 'lazy-view')
        local view = View.open('lazy')
        c:force_set(2)
        local frame = first_frame(c:get_op(Op), view)
        assert_eq(Util.unpack(frame.values), 2, 'view records proof-time first-access value')
        assert_eq(frame.evidence.dependencies.by_resource[c], 1, 'dependency records first-access version')
      end
      
      local function test_phase_token_required()
        local c = Cell.new(0, 'phase-cell')
        local view = View.open('phase')
        local ok = pcall(function()
          return Frontier.expand(c:get_op(Op), { id = 'attempt' }, view, nil)
        end)
        if ok then error('expected Frontier.expand to require a search phase token', 2) end
      end
      
      local function test_stale_is_distinct_from_absent()
        local c = Cell.new(1, 'status-cell')
        local view = View.open('status')
        local f = assert_status(expand(c:get_op(Op), { id = 'attempt-status' }, view), 'found')
        assert_status(probe(f, view), 'found')
        c:force_set(2)
        assert_status(probe(f, view), 'stale')
      
        local never = assert_status(expand(Op.never(), { id = 'attempt-never' }, View.open('never-status')), 'found')
        assert_status(probe(never, never.view), 'absent')
      end
      
      local function test_expired_phase_token_rejected()
        local saved
        Phase.with('search', function(token)
          saved = token
        end)
        local ok, err = pcall(function()
          return Frontier.expand(Op.always(1), { id = 'expired-attempt' }, View.open('expired-token'), saved)
        end)
        if ok then error('expected expired search token to be rejected', 2) end
        assert(tostring(err):match('expired token'), err)
      end
      
      local function test_emit_preserves_resource_identity()
        local c = Cell.new(0, 'descriptor-resource')
        local descriptor = { tag = 'touch', resource = c, nested = { resource = c } }
        local op = Op.emit(descriptor)
        descriptor.nested.resource = Cell.new(1, 'other-resource')
        local frame = first_frame(op, View.open('descriptor-identity'))
        local emitted = frame.evidence.consequences.transaction[1]
        assert_eq(emitted.resource, c, 'descriptor copier preserves top-level ET resource identity')
        assert_eq(emitted.nested.resource, c, 'descriptor copier preserves nested ET resource identity')
      end
      
      local function test_emit_rejects_unmarked_identity_table()
        local object = setmetatable({ tag = 'object' }, {})
        local ok, err = pcall(function()
          return Op.emit({ tag = 'bad', object = object })
        end)
        if ok then error('expected Op.emit to reject unmarked metatable table in descriptor', 2) end
        assert(tostring(err):match('unmarked identity table'), err)
      end
      
      local function test_strict_frontier_scheduling_staleness_blocks_probe()
        local c = Cell.new(0, 'strict-stale')
        local view = View.open('strict-frontier')
        local f = assert_status(expand(Op.always('pure'), { id = 'strict-attempt' }, view), 'found')
        assert_status(probe(f, view), 'found')
        assert(f.dependencies:add(c, c:current_version()))
        c:force_set(1)
        local stale = probe(f, view)
        assert_status(stale, 'stale', 'strict frontier scheduling staleness blocks even fresh frames')
        assert_eq(stale.resources[1], c, 'strict stale status names changed resource')
      end
      
      local function test_cell_resource_combine_stub()
        local c = Cell.new(0, 'combine-cell')
        local view = View.open('combine-view')
        in_search(function(token)
          local snap = assert_status(view:of(c), 'found')
          local empty = assert_status(Link.initial(view, c, snap, token), 'found')
          local left = assert_status(Link.claim(view, c, empty, { kind = 'access', request = { tag = 'set', value = 1 } }, token), 'found').fragment
          local right_read = assert_status(Link.claim(view, c, empty, { kind = 'access', request = { tag = 'get' } }, token), 'found').fragment
          local combined = assert_status(Link.merge(view, c, { kind = 'coexist', fragments = { left, right_read } }, token), 'found').fragment
          assert_eq(combined.value, 1, 'cell merge preserves write against read-only fragment')
          assert_eq(combined.written, true, 'cell merge keeps write marker')
      
          local same_write = assert_status(Link.claim(view, c, empty, { kind = 'access', request = { tag = 'set', value = 1 } }, token), 'found').fragment
          assert_status(Link.merge(view, c, { kind = 'coexist', fragments = { left, same_write } }, token), 'found', 'same cell write merges')
      
          local other_write = assert_status(Link.claim(view, c, empty, { kind = 'access', request = { tag = 'set', value = 2 } }, token), 'found').fragment
          assert_status(Link.merge(view, c, { kind = 'coexist', fragments = { left, other_write } }, token), 'conflict', 'conflicting cell writes conflict')
        end)
      end
      
      return function()
        test_always_never()
        test_bind_map()
        test_access_sequence()
        test_emit_and_wrap()
        test_boundary_blocks_transactional_sequence()
        test_stale_frontier_cannot_be_probed()
        test_refresh_produces_new_frontier_under_new_view()
        test_view_is_lazy_and_version_recording()
        test_phase_token_required()
        test_expired_phase_token_rejected()
        test_emit_preserves_resource_identity()
        test_emit_rejects_unmarked_identity_table()
        test_strict_frontier_scheduling_staleness_blocks_probe()
        test_cell_resource_combine_stub()
        test_stale_is_distinct_from_absent()
        print('frontier certificate tests: ok')
      end
    end)()
    _case()
  end
  do
    local _case = (function()
      package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
      
      local Op = require('et.op')
      local Runtime = require('et.runtime')
      local Channel = require('et.resources.channel')
      local Cell = require('et.resources.cell')
      local View = require('et.machine.frontier').View
      local Frontier = require('et.machine.frontier').Frontier
      local Obligation = require('et.machine.frontier').Obligation
      
      local function assert_eq(actual, expected, message)
        if actual ~= expected then
          error((message or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
        end
      end
      
      local function assert_status(x, tag, message)
        if not x or x.tag ~= tag then
          error((message or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag) .. ' (' .. tostring(x and x.reason) .. ')', 2)
        end
        return x.value
      end
      
      local function reset()
        if Obligation.reset_for_tests then Obligation.reset_for_tests() end
      end
      
      local function with_nack_callback_is_memoised_across_refresh()
        reset()
        local rt = Runtime.new()
        local cell = Cell.new(0, 'memo-nack-cell')
        local ch = Channel.new('memo-nack-block')
        local calls = 0
        local got_a, got_b
        local op = Op.with_nack(function(_nack)
          calls = calls + 1
          return cell:get_op(Op):and_then(function(v)
            if v == 0 then return ch:get_op(Op) end
            return Op.always('ok')
          end)
        end)
        rt:spawn(function() got_a = rt:perform(op) end, 'memo-nack-root')
        rt:spawn(function() got_b = rt:perform(cell:set_op(Op, 1):and_then(function() return Op.always('set') end)) end, 'memo-nack-setter')
        assert_status(rt:run(), 'found')
        assert_eq(got_b, 'set')
        assert_eq(got_a, 'ok')
        assert(rt.stats.refreshes >= 1, 'test should refresh the parked root')
        assert_eq(calls, 1, 'with_nack callback should be forced once for the live attempt occurrence')
      end
      
      local function with_nack_callback_runs_again_for_new_perform_attempt()
        reset()
        local rt = Runtime.new()
        local calls = 0
        local op = Op.with_nack(function(_nack)
          calls = calls + 1
          return Op.always('ok')
        end)
        local a, b
        rt:spawn(function()
          a = rt:perform(op)
          b = rt:perform(op)
        end, 'memo-nack-new-attempt')
        assert_status(rt:run(), 'found')
        assert_eq(a, 'ok')
        assert_eq(b, 'ok')
        assert_eq(calls, 2, 'new perform attempt gets fresh with_nack memo cells')
      end
      
      local function with_nack_choice_decision_prefixes_are_distinct()
        reset()
        local calls = 0
        local w = Op.with_nack(function(_nack)
          calls = calls + 1
          return Op.always('ok')
        end)
        local view = View.open('memo-choice-view')
        local frontier = assert_status(Frontier.expand_in_search(Op.choice(w, w), { id = 'memo-choice-attempt' }, view), 'found')
        assert(#frontier.frames >= 2, 'both choice branches should be represented')
        assert_eq(calls, 2, 'same syntax under different choice decision prefixes gets distinct memo cells')
      end
      
      local function with_nack_product_lanes_are_distinct()
        reset()
        local calls = 0
        local f = function(_nack)
          calls = calls + 1
          return Op.always('ok')
        end
        local view = View.open('memo-lanes-view')
        local frontier = assert_status(Frontier.expand_in_search(Op.tensor({ Op.with_nack(f), Op.with_nack(f) }), { id = 'memo-lanes-attempt' }, view), 'found')
        assert(#frontier.frames >= 1, 'product should expand')
        assert_eq(calls, 2, 'different product lanes get distinct with_nack memo cells')
      end
      
      local function nested_with_nack_identity_includes_parent_obligation()
        reset()
        local seen_parent = false
        local op = Op.with_nack(function(n1)
          return Op.with_nack(function(n2)
            seen_parent = n2.obligation.origin and n2.obligation.origin.parent_obligation == n1.obligation.id
            return Op.never()
          end)
        end)
        local view = View.open('memo-nested-view')
        assert_status(Frontier.expand_in_search(op, { id = 'memo-nested-attempt' }, view), 'found')
        assert(seen_parent, 'nested with_nack occurrence should include parent obligation identity')
      end
      
      local function guard_callback_is_memoised_across_refresh()
        reset()
        local rt = Runtime.new()
        local cell = Cell.new(0, 'memo-guard-cell')
        local ch = Channel.new('memo-guard-block')
        local calls = 0
        local got_a, got_b
        local op = Op.guard(function()
          calls = calls + 1
          return cell:get_op(Op):and_then(function(v)
            if v == 0 then return ch:get_op(Op) end
            return Op.always('ok')
          end)
        end)
        rt:spawn(function() got_a = rt:perform(op) end, 'memo-guard-root')
        rt:spawn(function() got_b = rt:perform(cell:set_op(Op, 1):and_then(function() return Op.always('set') end)) end, 'memo-guard-setter')
        assert_status(rt:run(), 'found')
        assert_eq(got_b, 'set')
        assert_eq(got_a, 'ok')
        assert(rt.stats.refreshes >= 1, 'test should refresh the guard root')
        assert_eq(calls, 1, 'guard callback should be forced once for the live attempt occurrence')
      end
      
      local function guard_callback_runs_again_for_new_perform_attempt()
        reset()
        local rt = Runtime.new()
        local calls = 0
        local op = Op.guard(function()
          calls = calls + 1
          return Op.always('ok')
        end)
        local a, b
        rt:spawn(function()
          a = rt:perform(op)
          b = rt:perform(op)
        end, 'memo-guard-new-attempt')
        assert_status(rt:run(), 'found')
        assert_eq(a, 'ok')
        assert_eq(b, 'ok')
        assert_eq(calls, 2, 'new perform attempt gets fresh guard memo cells')
      end
      
      return function()
        with_nack_callback_is_memoised_across_refresh()
        with_nack_callback_runs_again_for_new_perform_attempt()
        with_nack_choice_decision_prefixes_are_distinct()
        with_nack_product_lanes_are_distinct()
        nested_with_nack_identity_includes_parent_obligation()
        guard_callback_is_memoised_across_refresh()
        guard_callback_runs_again_for_new_perform_attempt()
        print('expansion memoisation tests: ok')
      end
    end)()
    _case()
  end
  print('machine/frontier tests: ok')
end
