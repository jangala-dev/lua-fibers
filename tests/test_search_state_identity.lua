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

local SearchCache = require('fibers.kernel.adaptive_search')

local function neq(left, right, message)
  if left == right then
    error(message or 'expected distinct exact state identities', 2)
  end
end

local request = {}
local op = { _id = 11 }
local program = { kind = 'exchange' }
local location = { id = 41, version = 3 }

local function state()
  local view1 = {
    root_id = 1,
    scope_path = {},
    merged = false,
    cells = { [location] = { version = 3, value = 'v' } },
    delta = {},
  }
  local view2 = {
    root_id = 1,
    scope_path = { { group_id = 1, mode = 'interacting', lane = 1 } },
    merged = false,
    cells = {},
    delta = {},
  }
  view1.id = 1
  view2.id = 2
  view2.parent = view1
  local task1 = {
    id = 1,
    root_id = 1,
    view_id = 1,
    status = 'blocked',
    expr = op,
    frames = {},
    scope_path = {},
    choice_serial = 0,
  }
  local task2 = {
    id = 2,
    root_id = 1,
    view_id = 2,
    status = 'done',
    expr = op,
    frames = { { kind = 'group_lane', group_id = 1, lane = 1 } },
    scope_path = { { group_id = 1, mode = 'interacting', lane = 1 } },
    choice_serial = 0,
  }
  local intent = {
    id = 1,
    task_id = 1,
    root_id = 1,
    kind = 'exchange',
    program = program,
    resource = {},
    role = 'get',
    scope_path = {},
  }
  return {
    focus = 1,
    roots = { [1] = { request = request, view_id = 1, done = false } },
    excluded_roots = {},
    tasks = { [1] = task1, [2] = task2 },
    active = { 1, 2 },
    active_head = 1,
    groups = {
      [1] = {
        id = 1,
        parent_task = 1,
        parent_view = 1,
        mode = 'interacting',
        count = 1,
        completed = 1,
        lane_views = { 2 },
        lane_outcomes = { { pack = { n = 0 } } },
      },
    },
    intents = { intent },
    intent_by_id = { [1] = intent },
    views = { [1] = view1, [2] = view2 },
    effects = {},
    negative_checks = {},
    fallback_interests = {},
    used_fallback = false,
    next_task = 2,
    next_group = 1,
    next_view = 2,
    next_intent = 1,
    next_machine_serial = 0,
  }
end

local base = state()
local base_key = SearchCache.signature(base, false)

local changed = state()
changed.tasks[1].view_id = 2
neq(base_key, SearchCache.signature(changed, false), 'task-to-view relationship was omitted')

changed = state()
changed.groups[1].parent_task = 2
neq(base_key, SearchCache.signature(changed, false), 'group parent task was omitted')

changed = state()
changed.groups[1].lane_views[1] = 1
neq(base_key, SearchCache.signature(changed, false), 'group lane view was omitted')

changed = state()
changed.intents[1].task_id = 2
changed.intent_by_id[1] = changed.intents[1]
neq(base_key, SearchCache.signature(changed, false), 'intent-to-task relationship was omitted')

changed = state()
changed.active = { 2, 1 }
neq(base_key, SearchCache.signature(changed, false), 'active task order was omitted')

changed = state()
changed.views[2].parent = nil
neq(base_key, SearchCache.signature(changed, false), 'view parent relationship was omitted')

print('tests/test_search_state_identity.lua: ok')
