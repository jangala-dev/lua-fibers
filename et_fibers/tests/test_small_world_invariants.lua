package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

return function()
  local Op = require('et.op')
  local Runtime = require('et.runtime')
  local Cell = require('et.resources.cell')
  local Queue = require('et.resources.queue')
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

  local function table_values(t)
    local out = {}
    for k, v in pairs(t or {}) do out[#out + 1] = { key = k, value = v } end
    return out
  end

  local function assert_no_stale_frontiers(rt, name)
    for i = 1, #(rt.waiting or {}) do
      local task = rt.waiting[i]
      if task.frontier then
        assert(not task.frontier_stale, name .. ': stale flag left at fixpoint')
        assert(task.frontier:is_fresh(task.view), name .. ': stale frontier left at fixpoint')
      end
    end
  end

  local function assert_no_failed_tasks(rt, name)
    for i = 1, #(rt.tasks or {}) do
      local task = rt.tasks[i]
      assert(task.state ~= 'failed', name .. ': task failed: ' .. tostring(task.error and task.error.reason or task.error))
    end
  end

  local function assert_obligations_terminal_or_unpublished(rt, name)
    local cells = table_values((rt.obligations or {}).cells)
    for i = 1, #cells do
      local cell = cells[i].value
      local s = cell.state
      assert(s == 'unpublished' or s == 'selected' or s == 'lost' or s == 'withdrawn' or s == 'discharged',
        name .. ': obligation left in non-terminal state ' .. tostring(s))
    end
  end

  local function run_scenario(name, spawn_fn, expected)
    local published = {}
    local rt = Runtime.new({
      quiet_deadlock = true,
      on_consequence = function(log) published[#published + 1] = log end,
    })
    local state = {}
    spawn_fn(rt, state)
    local status = rt:run()

    if expected and expected.status then assert_eq(status.tag, expected.status, name .. ': status') end
    if status.tag == 'found' then
      assert_no_failed_tasks(rt, name)
      for i = 1, #rt.tasks do assert_eq(rt.tasks[i].state, 'done', name .. ': found run leaves task not done') end
      assert_eq(#rt.waiting, 0, name .. ': found run leaves waiting tasks')
      assert_eq(#rt.runnable, 0, name .. ': found run leaves runnable tasks')
    else
      assert_no_stale_frontiers(rt, name)
    end
    assert((#published <= rt.stats.commits), name .. ': consequences published more often than commits')
    assert_obligations_terminal_or_unpublished(rt, name)
    if expected and expected.check then expected.check(rt, state, status, published) end
  end

  local scenarios = {}

  scenarios[#scenarios + 1] = {
    name = 'pure always plus emit',
    status = 'found',
    spawn = function(rt, state)
      rt:spawn(function()
        state.value = rt:perform(Op.emit({ tag = 'small-world' }):and_then(function() return Op.always('ok') end))
      end, 'pure')
    end,
    check = function(rt, state, _status, published)
      assert_eq(state.value, 'ok')
      assert_eq(rt.stats.commits, 1)
      assert_eq(#published, 1)
      assert_eq(published[1].transaction[1].tag, 'small-world')
    end,
  }

  scenarios[#scenarios + 1] = {
    name = 'two stale cell updaters reach fixpoint',
    status = 'found',
    spawn = function(rt, state)
      state.cell = Cell.new(0, 'small-cell')
      rt:spawn(function() state.a = rt:perform(state.cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-a')
      rt:spawn(function() state.b = rt:perform(state.cell:update_op(Op, function(v) return v + 1 end)) end, 'cell-b')
    end,
    check = function(rt, state)
      assert_eq(state.cell.value, 2)
      assert_eq(state.a, 1)
      assert_eq(state.b, 2)
      assert(rt.stats.refreshes >= 1, 'stale retry scenario should refresh')
    end,
  }

  scenarios[#scenarios + 1] = {
    name = 'channel rendezvous consumes both roots',
    status = 'found',
    spawn = function(rt, state)
      state.ch = Channel.new('small-channel')
      rt:spawn(function() state.put = rt:perform(state.ch:put_op(Op, 'msg')) end, 'put')
      rt:spawn(function() state.get = rt:perform(state.ch:get_op(Op)) end, 'get')
    end,
    check = function(_rt, state)
      assert_eq(state.put, true)
      assert_eq(state.get, 'msg')
    end,
  }

  scenarios[#scenarios + 1] = {
    name = 'all sibling rendezvous absent at true fixpoint',
    status = 'absent',
    spawn = function(rt, state)
      state.ch = Channel.new('small-all-absent')
      rt:spawn(function() state.x = rt:perform(Op.all({ state.ch:put_op(Op, 'x'), state.ch:get_op(Op) })) end, 'all')
    end,
    check = function(_rt, state)
      assert_eq(state.x, nil)
    end,
  }

  scenarios[#scenarios + 1] = {
    name = 'queue wake publishes before pop waiter resumes',
    status = 'found',
    spawn = function(rt, state)
      state.queue = Queue.new({}, 'small-queue')
      rt:spawn(function() state.popped = rt:perform(state.queue:pop_wait_op(Op)) end, 'pop-wait')
      rt:spawn(function() state.pushed = rt:perform(state.queue:push_op(Op, 'item')) end, 'push')
    end,
    check = function(_rt, state, _status, published)
      assert_eq(state.pushed, true)
      assert_eq(state.popped, 'item')
      local saw_wake = false
      for i = 1, #published do
        for j = 1, #(published[i].resource or {}) do
          local e = published[i].resource[j]; if (e.kind or e.tag) == 'wake' then saw_wake = true end
        end
      end
      assert(saw_wake, 'queue transition from empty to nonempty publishes wake')
    end,
  }

  scenarios[#scenarios + 1] = {
    name = 'choice losing consequence absent',
    status = 'found',
    spawn = function(rt, state)
      rt:spawn(function()
        state.result = rt:perform(
          Op.never():choice(Op.emit({ tag = 'winner' }):and_then(function() return Op.always('winner') end))
        )
      end, 'choice')
    end,
    check = function(_rt, state, _status, published)
      assert_eq(state.result, 'winner')
      assert_eq(#published[1].transaction, 1)
      assert_eq(published[1].transaction[1].tag, 'winner')
    end,
  }

  scenarios[#scenarios + 1] = {
    name = 'with_nack selected obligation terminal',
    status = 'found',
    spawn = function(rt, state)
      rt:spawn(function()
        state.result = rt:perform(Op.with_nack(function(_nack)
          return Op.always('selected')
        end))
      end, 'nack-selected')
    end,
    check = function(rt, state)
      assert_eq(state.result, 'selected')
      local terminal = false
      for _, cell in pairs(rt.obligations.cells) do
        if cell.state == 'selected' then terminal = true end
      end
      assert(terminal, 'selected with_nack obligation should be terminal')
    end,
  }

  for i = 1, #scenarios do
    run_scenario(scenarios[i].name, scenarios[i].spawn, scenarios[i])
  end

  print('small-world invariant explorer: ok')
end
