package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

return function()
  local Protocol = require('et.protocol')
  local Cell = require('et.resources.cell')
  local Queue = require('et.resources.queue')
  local Op = require('et.op')
  local Runtime = require('et.runtime')

  local Link = Protocol.Link
  local Values = Protocol.Values
  local Kernel = require('et.kernel')
  local Machine = require('et.machine')
  local Phase = Kernel.Phase
  local Status = Kernel.Status
  local View = Machine.Frontier.View

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

  local function same_items(a, b)
    a = a or {}; b = b or {}
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end

  local function search(fn)
    return Phase.with('search', function(token) return fn(token) end)
  end

  local function prepare(fn)
    return Phase.with('prepare', function(token) return fn(token) end)
  end

  local function commit(fn)
    return Phase.with('commit', function(token) return fn(token) end)
  end

  local function initial(view, resource, token)
    local snap = assert_status(Link.snapshot(view, resource), 'found')
    local frag = assert_status(Link.initial(view, resource, snap, token), 'found')
    return snap, frag
  end

  local function cell_claim(view, cell, fragment, tag, value, token)
    return assert_status(Link.claim(view, cell, fragment, {
      kind = 'access',
      request = { tag = tag, value = value },
    }, token), 'found')
  end

  local function test_cell_fragment_algebra()
    local cell = Cell.new(0, 'law-cell')
    local view = View.open('law-cell-view')
    local f0, set1, set1b, set2

    search(function(token)
      local _snap
      _snap, f0 = initial(view, cell, token)
      set1 = cell_claim(view, cell, f0, 'set', 1, token).fragment
      set1b = cell_claim(view, cell, f0, 'set', 1, token).fragment
      set2 = cell_claim(view, cell, f0, 'set', 2, token).fragment

      local id_left = assert_status(Link.merge(view, cell, { kind = 'coexist', fragments = { f0, set1 } }, token), 'found').fragment
      assert_eq(id_left.value, 1, 'cell merge identity preserves write')

      local id_right = assert_status(Link.merge(view, cell, { kind = 'coexist', fragments = { set1, f0 } }, token), 'found').fragment
      assert_eq(id_right.value, 1, 'cell merge identity is symmetric')

      local same = assert_status(Link.merge(view, cell, { kind = 'coexist', fragments = { set1, set1b } }, token), 'found').fragment
      assert_eq(same.value, 1, 'same write coexists')

      local conflict = Link.merge(view, cell, { kind = 'coexist', fragments = { set1, set2 } }, token)
      assert_eq(conflict.tag, 'conflict', 'different writes conflict')

      local extended = assert_status(Link.merge(view, cell, { kind = 'extend', base = f0, fragments = { set1 } }, token), 'found').fragment
      assert_eq(extended.value, 1, 'extend applies delta')

      local projected = assert_status(Link.merge(view, cell, { kind = 'project', base = f0, fragments = { set1 } }, token), 'found').fragment
      assert(projected and projected.written, 'project returns write delta')
    end)

    local before_value, before_version = cell.value, cell.version
    local prepared = prepare(function(token) return assert_status(Link.prepare(cell, set1, token), 'found') end)
    assert_eq(cell.value, before_value, 'cell prepare is pure')
    assert_eq(cell.version, before_version, 'cell prepare does not advance version')
    assert_status(commit(function(token) return Link.commit(prepared, token) end), 'found')
    assert_eq(cell.value, 1, 'cell commit applies prepared fragment')
    assert_eq(cell.version, 1, 'cell commit advances version once')

    local stale = prepare(function(token) return Link.prepare(cell, set2, token) end)
    assert_eq(stale.tag, 'stale', 'old cell fragment becomes stale after commit')
  end

  local function queue_claim(view, queue, fragment, tag, value, token)
    return Link.claim(view, queue, fragment, {
      kind = 'access',
      request = { tag = tag, value = value },
    }, token)
  end

  local function test_queue_fragment_algebra()
    local queue = Queue.new({}, 'law-queue')
    local view = View.open('law-queue-view')
    local f0, push_a, push_a_again, push_b

    search(function(token)
      local _snap
      _snap, f0 = initial(view, queue, token)
      push_a = assert_status(queue_claim(view, queue, f0, 'push', 'a', token), 'found').fragment
      push_a_again = assert_status(queue_claim(view, queue, f0, 'push', 'a', token), 'found').fragment
      push_b = assert_status(queue_claim(view, queue, f0, 'push', 'b', token), 'found').fragment

      local id_left = assert_status(Link.merge(view, queue, { kind = 'coexist', fragments = { f0, push_a } }, token), 'found').fragment
      assert(same_items(id_left.items, { 'a' }), 'queue merge identity preserves push')

      local same = assert_status(Link.merge(view, queue, { kind = 'coexist', fragments = { push_a, push_a_again } }, token), 'found').fragment
      assert(same_items(same.items, { 'a' }), 'same queue edit coexists')

      local conflict = Link.merge(view, queue, { kind = 'coexist', fragments = { push_a, push_b } }, token)
      assert_eq(conflict.tag, 'conflict', 'parallel different queue edits conflict')

      local absent = queue_claim(view, queue, f0, 'pop', nil, token)
      assert_eq(absent.tag, 'absent', 'empty queue pop is logical absence')

      local pending = Link.claim(view, queue, nil, { kind = 'await', request = { tag = 'nonempty' } }, token)
      assert_eq(pending.tag, 'pending', 'empty queue await registers pending wait')
      assert(pending.detail and pending.detail.dependencies, 'pending queue await records dependency')
    end)

    local prepared = prepare(function(token) return assert_status(Link.prepare(queue, push_a, token), 'found') end)
    assert_eq(queue:length(), 0, 'queue prepare is pure')
    assert_status(commit(function(token) return Link.commit(prepared, token) end), 'found')
    assert_eq(queue:length(), 1, 'queue commit applies push')
    assert_eq(queue:to_table()[1], 'a')
  end

  local function test_commit_false_is_fatal_and_does_not_resume()
    local BadClass = Link.resource {
      name = 'law-bad-commit',
      construct = function(self) self.version = 0; self.commits = 0 end,
      snapshot = function(self) return { resource = self, version = self.version } end,
      initial = function(_self, snap) return { base_version = snap.version } end,
      claim = function(_self, _snap, fragment, _claim, ctx) return ctx:accept(fragment, true) end,
      merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
      prepare = function(self, fragment, ctx)
        return ctx:prepared({ resource = self, fragment = fragment, dirty = {}, consequences = { transaction = {}, resource = {}, obligation = {} } })
      end,
      commit = function(self)
        self.commits = self.commits + 1
        return false
      end,
    }
    local Bad = BadClass.new()

    local prepared = search(function(token)
      local view = View.open('law-bad-commit-view')
      local _snap, f0 = initial(view, Bad, token)
      return assert_status(Link.claim(view, Bad, f0, { kind = 'access', request = { tag = 'go' } }, token), 'found').fragment
    end)
    local prep = prepare(function(token) return assert_status(Link.prepare(Bad, prepared, token), 'found') end)
    local direct = commit(function(token) return Link.commit(prep, token) end)
    assert_eq(direct.tag, 'fatal', 'Link.commit treats false as fatal')

    local rt = Runtime.new({ quiet_deadlock = true })
    local result
    rt:spawn(function() result = rt:perform(Op.access(Bad, { tag = 'go' })) end, 'bad-commit')
    local st = rt:run()
    assert_eq(st.tag, 'fatal', 'runtime surfaces bad resource commit')
    assert_eq(result, nil, 'participant is not resumed after bad commit')
  end

  test_cell_fragment_algebra()
  test_queue_fragment_algebra()
  test_commit_false_is_fatal_and_does_not_resume()
  print('protocol/link resource-law harness: ok')
end
