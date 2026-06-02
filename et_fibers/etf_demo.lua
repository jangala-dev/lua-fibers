-- etf_demo.lua
--
-- A deliberately tiny, single-file, Lua 5.1/texlua runnable sketch of an
-- Eventful Transactions / proof-net flavoured runtime.
--
-- It is not the full library.  It is the smallest useful physical model:
--
--   * an Op algebra
--   * parked roots elaborate to proof rows
--   * wait rows are open ports
--   * channel rendezvous is a cut between dual ports
--   * resources contribute mergeable fragments
--   * a closed candidate becomes a World
--   * World commit validates fragments, emits commit events, installs state,
--     then resumes participating fibres
--
-- Demos at the bottom:
--   1. triple swap over synchronous channels
--   2. ledger transfer + close as one atomic transaction with commit events

local unpack_ = rawget(table, 'unpack') or _G.unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function unpack_pack(p)
  return unpack_(p, 1, p.n or #p)
end

local function list_append(dst, src)
  if src then
    for i = 1, #src do dst[#dst + 1] = src[i] end
  end
end

local function shallow_copy(t)
  local u = {}
  if t then for k, v in pairs(t) do u[k] = v end end
  return u
end

local function list_copy(xs)
  local ys = {}
  if xs then for i = 1, #xs do ys[i] = xs[i] end end
  return ys
end

local function clone_env(env)
  local e = {
    fragments = {},
    fragment_order = list_copy(env and env.fragment_order),
    consequences = list_copy(env and env.consequences),
  }
  if env and env.fragments then
    for k, v in pairs(env.fragments) do e.fragments[k] = v end
  end
  return e
end

local function empty_env()
  return { fragments = {}, fragment_order = {}, consequences = {} }
end

local function set_fragment(env, resource, fragment)
  if env.fragments[resource] == nil then
    env.fragment_order[#env.fragment_order + 1] = resource
  end
  env.fragments[resource] = fragment
end

local function merge_fragment_into_env(env, resource, fragment)
  local current = env.fragments[resource]
  if current == nil then
    set_fragment(env, resource, fragment)
    return true
  end
  local ok, merged_or_reason = resource:merge_fragments(current, fragment)
  if not ok then return false, merged_or_reason end
  env.fragments[resource] = merged_or_reason
  return true
end

local function merge_response(env, response)
  response = response or {}

  if response.fragments then
    for resource, fragment in pairs(response.fragments) do
      local ok, reason = merge_fragment_into_env(env, resource, fragment)
      if not ok then return nil, reason end
    end
  end

  if response.consequences then
    list_append(env.consequences, response.consequences)
  end

  return env
end

local function response_values(response)
  response = response or {}
  if response.values then return response.values end
  if response.value ~= nil then return pack(response.value) end
  return pack()
end

-- --------------------------------------------------------------------------
-- Op algebra
-- --------------------------------------------------------------------------

local Op = {}
local OpMethods = {}
OpMethods.__index = OpMethods

local function new_op(tag, fields)
  fields = fields or {}
  fields.tag = tag
  return setmetatable(fields, OpMethods)
end

function Op.always(...)
  return new_op('always', { values = pack(...) })
end

function Op.never()
  return new_op('never')
end

function Op.choice(...)
  local n = select('#', ...)
  if n == 0 then return Op.never() end
  local op = select(1, ...)
  for i = 2, n do op = op:choice(select(i, ...)) end
  return op
end

function Op.request(resource, request)
  return new_op('request', { resource = resource, request = request })
end

function Op.access(resource, request)
  return new_op('access', { resource = resource, request = request })
end

function Op.emit(event)
  return new_op('emit', { event = event })
end

function Op.perform(op)
  return coroutine.yield(op)
end

function OpMethods:and_then(k)
  return new_op('bind', { op = self, k = k })
end

function OpMethods:map(f)
  return self:and_then(function(...)
    return Op.always(f(...))
  end)
end

function OpMethods:choice(other)
  return new_op('choice', { left = self, right = other })
end

-- --------------------------------------------------------------------------
-- Rows: the tiny proof frontier.
--
-- done row: a closed proof for one participant/lane.
-- wait row: an open resource port; must be cut with a compatible port.
-- --------------------------------------------------------------------------

local function row_done(values, env)
  return { kind = 'done', values = values or pack(), env = env }
end

local function row_wait(resource, request, env, cont)
  return { kind = 'wait', resource = resource, request = request, env = env, cont = cont }
end

local eval_op

local function eval_after_wait(row, response)
  local env = clone_env(row.env)
  local ok_env, reason = merge_response(env, response)
  if not ok_env then return {} end
  local next_op = row.cont(response_values(response))
  return eval_op(next_op, env)
end

eval_op = function(op, env)
  env = env or empty_env()

  if op.tag == 'always' then
    return { row_done(op.values, clone_env(env)) }

  elseif op.tag == 'never' then
    return {}

  elseif op.tag == 'choice' then
    local out = eval_op(op.left, clone_env(env))
    list_append(out, eval_op(op.right, clone_env(env)))
    return out

  elseif op.tag == 'bind' then
    local out = {}
    local rows = eval_op(op.op, clone_env(env))
    for i = 1, #rows do
      local r = rows[i]
      if r.kind == 'done' then
        local next_op = op.k(unpack_pack(r.values))
        list_append(out, eval_op(next_op, r.env))
      elseif r.kind == 'wait' then
        local old = r
        out[#out + 1] = row_wait(old.resource, old.request, old.env, function(values)
          return old.cont(values):and_then(op.k)
        end)
      end
    end
    return out

  elseif op.tag == 'request' then
    return {
      row_wait(op.resource, op.request, clone_env(env), function(values)
        return Op.always(unpack_pack(values))
      end)
    }

  elseif op.tag == 'access' then
    local env2 = clone_env(env)
    local current = env2.fragments[op.resource]
    if current == nil then current = op.resource:empty_fragment() end

    local ok, response, next_fragment = op.resource:step_fragment(current, op.request)
    if not ok then return {} end

    set_fragment(env2, op.resource, next_fragment)
    local ok_env = merge_response(env2, response)
    if not ok_env then return {} end

    return { row_done(response_values(response), env2) }

  elseif op.tag == 'emit' then
    local env2 = clone_env(env)
    env2.consequences[#env2.consequences + 1] = op.event
    return { row_done(pack(), env2) }

  else
    error('unknown op tag: ' .. tostring(op.tag))
  end
end

-- --------------------------------------------------------------------------
-- Channel resource: put/get ports cut against each other.
-- --------------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new(name)
  return setmetatable({ name = name or 'channel' }, Channel)
end

function Channel:put(value)
  return Op.request(self, { tag = 'put', value = value })
end

function Channel:get()
  return Op.request(self, { tag = 'get' })
end

function Channel:empty_fragment()
  return { matches = {} }
end

function Channel:merge_fragments(a, b)
  local out = { matches = {} }
  for k, v in pairs(a.matches or {}) do out.matches[k] = v end
  for k, v in pairs(b.matches or {}) do
    local old = out.matches[k]
    if old and old ~= v then return false, 'channel match conflict' end
    out.matches[k] = v
  end
  return true, out
end

function Channel:validate_fragment(_) return true end
function Channel:prepare_commit_fragment(_, _) end
function Channel:commit_fragment(_) end

function Channel:try_match(a, b)
  if a.tag == 'put' and b.tag == 'get' then
    local token = {}
    local fragment = { matches = { [token] = a.value } }
    return true,
      { value = true, fragments = { [self] = fragment } },
      { value = a.value, fragments = { [self] = fragment } }

  elseif a.tag == 'get' and b.tag == 'put' then
    local token = {}
    local fragment = { matches = { [token] = b.value } }
    return true,
      { value = b.value, fragments = { [self] = fragment } },
      { value = true, fragments = { [self] = fragment } }
  end

  return false
end

-- --------------------------------------------------------------------------
-- Ledger resource: native fragments + commit events.
--
-- State: item -> owner, and closed owners.
-- Fragment: planned moves and closes.  Transfer+close-source is legal if the
-- close leaves the owner with no remaining items after planned moves.
-- --------------------------------------------------------------------------

local Ledger = {}
Ledger.__index = Ledger

function Ledger.new(owners)
  return setmetatable({ owners = shallow_copy(owners or {}), closed = {} }, Ledger)
end

function Ledger:move(item, from_owner, to_owner)
  return Op.access(self, { tag = 'move', item = item, from = from_owner, to = to_owner })
end

function Ledger:close(owner, reason)
  return Op.access(self, { tag = 'close', owner = owner, reason = reason or 'closed' })
end

function Ledger:empty_fragment()
  return { moves = {}, move_order = {}, closes = {}, close_order = {} }
end

local function ledger_clone_fragment(f)
  local g = { moves = {}, move_order = list_copy(f.move_order), closes = {}, close_order = list_copy(f.close_order) }
  for k, v in pairs(f.moves or {}) do g.moves[k] = { item = v.item, from = v.from, to = v.to } end
  for k, v in pairs(f.closes or {}) do g.closes[k] = { owner = v.owner, reason = v.reason } end
  return g
end

function Ledger:step_fragment(fragment, request)
  local f = ledger_clone_fragment(fragment)

  if request.tag == 'move' then
    local old = f.moves[request.item]
    local move = { item = request.item, from = request.from, to = request.to }
    if old and (old.from ~= move.from or old.to ~= move.to) then
      return false, 'conflicting move for ' .. tostring(request.item)
    end
    if not old then f.move_order[#f.move_order + 1] = request.item end
    f.moves[request.item] = move
    return true, { value = true }, f

  elseif request.tag == 'close' then
    local old = f.closes[request.owner]
    local close = { owner = request.owner, reason = request.reason }
    if old and old.reason ~= close.reason then
      return false, 'conflicting close for ' .. tostring(request.owner)
    end
    if not old then f.close_order[#f.close_order + 1] = request.owner end
    f.closes[request.owner] = close
    return true, { value = true }, f
  end

  return false, 'unknown ledger request'
end

function Ledger:merge_fragments(a, b)
  local out = ledger_clone_fragment(a)

  for _, item in ipairs(b.move_order or {}) do
    local mv = b.moves[item]
    local old = out.moves[item]
    if old and (old.from ~= mv.from or old.to ~= mv.to) then
      return false, 'conflicting move for ' .. tostring(item)
    end
    if not old then out.move_order[#out.move_order + 1] = item end
    out.moves[item] = { item = mv.item, from = mv.from, to = mv.to }
  end

  for _, owner in ipairs(b.close_order or {}) do
    local cl = b.closes[owner]
    local old = out.closes[owner]
    if old and old.reason ~= cl.reason then
      return false, 'conflicting close for ' .. tostring(owner)
    end
    if not old then out.close_order[#out.close_order + 1] = owner end
    out.closes[owner] = { owner = cl.owner, reason = cl.reason }
  end

  return true, out
end

function Ledger:validate_fragment(fragment)
  -- Validate moves against committed state and planned closes.
  local planned_owner = shallow_copy(self.owners)

  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    if self.closed[mv.from] then return false, 'source owner already closed: ' .. tostring(mv.from) end
    if self.closed[mv.to] then return false, 'target owner already closed: ' .. tostring(mv.to) end
    if planned_owner[item] ~= mv.from then
      return false, 'owner mismatch for ' .. tostring(item) .. ': expected ' .. tostring(mv.from) .. ', have ' .. tostring(planned_owner[item])
    end
    planned_owner[item] = mv.to
  end

  for _, owner in ipairs(fragment.close_order or {}) do
    if self.closed[owner] then return false, 'already closed: ' .. tostring(owner) end
    for item, item_owner in pairs(planned_owner) do
      if item_owner == owner then
        return false, 'cannot close non-empty owner ' .. tostring(owner) .. '; still owns ' .. tostring(item)
      end
    end
  end

  return true
end

function Ledger:prepare_commit_fragment(fragment, commit)
  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    commit:emit({ tag = 'ledger.move', item = mv.item, from = mv.from, to = mv.to })
  end
  for _, owner in ipairs(fragment.close_order or {}) do
    local cl = fragment.closes[owner]
    commit:emit({ tag = 'ledger.close', owner = cl.owner, reason = cl.reason })
  end
end

function Ledger:commit_fragment(fragment)
  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    self.owners[item] = mv.to
  end
  for _, owner in ipairs(fragment.close_order or {}) do
    local cl = fragment.closes[owner]
    self.closed[owner] = cl.reason
  end
end

-- --------------------------------------------------------------------------
-- World: a closed proof ready to commit.
-- --------------------------------------------------------------------------

local World = {}
World.__index = World

local function merge_world_fragments(entries)
  local fragments = {}
  local fragment_order = {}
  local consequences = {}

  local function merge_resource(resource, fragment)
    local current = fragments[resource]
    if current == nil then
      fragments[resource] = fragment
      fragment_order[#fragment_order + 1] = resource
      return true
    end
    local ok, merged_or_reason = resource:merge_fragments(current, fragment)
    if not ok then return false, merged_or_reason end
    fragments[resource] = merged_or_reason
    return true
  end

  for _, entry in ipairs(entries) do
    local env = entry.row.env
    for _, resource in ipairs(env.fragment_order or {}) do
      local ok, reason = merge_resource(resource, env.fragments[resource])
      if not ok then return nil, reason end
    end
    list_append(consequences, env.consequences)
  end

  for _, resource in ipairs(fragment_order) do
    local ok, reason = resource:validate_fragment(fragments[resource])
    if not ok then return nil, reason end
  end

  return fragments, fragment_order, consequences
end

function World.from_entries(entries)
  for _, entry in ipairs(entries) do
    if entry.row.kind ~= 'done' then return nil, 'world is not closed' end
  end

  local fragments, fragment_order, consequences_or_reason = merge_world_fragments(entries)
  if not fragments then return nil, consequences_or_reason end

  return setmetatable({
    entries = entries,
    fragments = fragments,
    fragment_order = fragment_order,
    consequences = consequences_or_reason,
  }, World)
end

local Commit = {}
Commit.__index = Commit

function Commit.new()
  return setmetatable({ events = {} }, Commit)
end

function Commit:emit(event)
  self.events[#self.events + 1] = event
end

local function print_event(event)
  if event.tag == 'ledger.move' then
    print(string.format('[commit event] move %s: %s -> %s', tostring(event.item), tostring(event.from), tostring(event.to)))
  elseif event.tag == 'ledger.close' then
    print(string.format('[commit event] close %s reason=%s', tostring(event.owner), tostring(event.reason)))
  else
    print('[commit event] ' .. tostring(event.tag))
  end
end

function World:commit(runtime)
  local commit = Commit.new()

  -- First collect commit events without installing state.
  for _, resource in ipairs(self.fragment_order) do
    if resource.prepare_commit_fragment then
      resource:prepare_commit_fragment(self.fragments[resource], commit)
    end
  end
  list_append(commit.events, self.consequences)

  -- Then install state.
  for _, resource in ipairs(self.fragment_order) do
    if resource.commit_fragment then
      resource:commit_fragment(self.fragments[resource])
    end
  end

  -- Then interpret commit events.
  for _, event in ipairs(commit.events) do print_event(event) end

  -- Finally resume each participating root once.
  for _, entry in ipairs(self.entries) do
    runtime:unpark(entry.task)
    entry.task.values = entry.row.values
    runtime.runnable[#runtime.runnable + 1] = entry.task
  end
end

-- --------------------------------------------------------------------------
-- Runtime / proof search.
-- --------------------------------------------------------------------------

local Runtime = {}
Runtime.__index = Runtime

function Runtime.new()
  return setmetatable({
    runnable = {},
    waiting = {},
    waiting_set = {},
    next_task_id = 0,
  }, Runtime)
end

function Runtime:spawn(fn, name)
  self.next_task_id = self.next_task_id + 1
  local task = {
    id = self.next_task_id,
    name = name or ('task-' .. tostring(self.next_task_id)),
    co = coroutine.create(fn),
    values = pack(),
    rows = nil,
    parked = false,
  }
  self.runnable[#self.runnable + 1] = task
  return task
end

function Runtime:park(task, op)
  task.rows = eval_op(op, empty_env())
  task.parked = true
  if not self.waiting_set[task] then
    self.waiting[#self.waiting + 1] = task
    self.waiting_set[task] = true
  end
end

function Runtime:unpark(task)
  if not self.waiting_set[task] then return end
  self.waiting_set[task] = nil
  task.parked = false
  task.rows = nil
  for i = #self.waiting, 1, -1 do
    if self.waiting[i] == task then table.remove(self.waiting, i); return end
  end
end

function Runtime:resume_task(task)
  local ok, yielded = coroutine.resume(task.co, unpack_pack(task.values))
  task.values = pack()

  if not ok then error(task.name .. ': ' .. tostring(yielded)) end
  if coroutine.status(task.co) == 'dead' then return end

  if type(yielded) ~= 'table' or not yielded.tag then
    error(task.name .. ': yielded non-operation')
  end

  self:park(task, yielded)
end

local function copy_entries(entries)
  local out = {}
  for i = 1, #entries do out[i] = entries[i] end
  return out
end

local function all_entries_done(entries)
  for i = 1, #entries do
    if entries[i].row.kind ~= 'done' then return false end
  end
  return true
end

local function try_match_rows(a, b)
  if a.kind ~= 'wait' or b.kind ~= 'wait' then return nil end
  if a.resource ~= b.resource then return nil end
  local ok, resp_a, resp_b = a.resource:try_match(a.request, b.request)
  if ok then return resp_a, resp_b end
  return nil
end

function Runtime:search_closed_world(entries, used_tasks)
  -- Closed proof: all ports are cut and every participant is done.
  if all_entries_done(entries) then
    return World.from_entries(entries)
  end

  -- Try every open port, not just the first.  This matters for TE-style
  -- multi-step protocols such as triple swap: one participant may need a
  -- different participant to progress before its own reply port can close.
  for wi = 1, #entries do
    local waiting_entry = entries[wi]
    local waiting_row = waiting_entry.row

    if waiting_row.kind == 'wait' then
      -- First try cuts with ports already inside this partial proof.
      for j = 1, #entries do
        if j ~= wi then
          local other_row = entries[j].row
          local resp_w, resp_o = try_match_rows(waiting_row, other_row)
          if resp_w then
            local next_ws = eval_after_wait(waiting_row, resp_w)
            local next_os = eval_after_wait(other_row, resp_o)
            for a = 1, #next_ws do
              for b = 1, #next_os do
                local next_entries = copy_entries(entries)
                next_entries[wi] = { task = waiting_entry.task, row = next_ws[a] }
                next_entries[j] = { task = entries[j].task, row = next_os[b] }
                local world = self:search_closed_world(next_entries, used_tasks)
                if world then return world end
              end
            end
          end
        end
      end

      -- Then try cuts by drawing in another parked root.
      for _, task in ipairs(self.waiting) do
        if task.parked and not used_tasks[task] then
          for _, other_row in ipairs(task.rows or {}) do
            local resp_w, resp_o = try_match_rows(waiting_row, other_row)
            if resp_w then
              local next_ws = eval_after_wait(waiting_row, resp_w)
              local next_os = eval_after_wait(other_row, resp_o)
              for a = 1, #next_ws do
                for b = 1, #next_os do
                  local next_entries = copy_entries(entries)
                  next_entries[wi] = { task = waiting_entry.task, row = next_ws[a] }
                  next_entries[#next_entries + 1] = { task = task, row = next_os[b] }
                  local next_used = shallow_copy(used_tasks)
                  next_used[task] = true
                  local world = self:search_closed_world(next_entries, next_used)
                  if world then return world end
                end
              end
            end
          end
        end
      end
    end
  end

  return nil
end

function Runtime:try_commit_one()
  for _, task in ipairs(self.waiting) do
    if task.parked then
      for _, row in ipairs(task.rows or {}) do
        local used = { [task] = true }
        local world = self:search_closed_world({ { task = task, row = row } }, used)
        if world then
          world:commit(self)
          return true
        end
      end
    end
  end
  return false
end

function Runtime:run()
  while true do
    while #self.runnable > 0 do
      local task = table.remove(self.runnable, 1)
      self:resume_task(task)
    end

    if #self.waiting == 0 then return end

    if not self:try_commit_one() then
      io.stderr:write('deadlock: no closed proof can be constructed\n')
      for _, task in ipairs(self.waiting) do
        io.stderr:write('  waiting: ' .. tostring(task.name) .. '\n')
      end
      error('deadlock')
    end
  end
end

-- --------------------------------------------------------------------------
-- Demo 1: Triple swap
-- --------------------------------------------------------------------------

local function pair(a, b)
  return { a, b }
end

local function triple_swap_op(ch, x)
  local reply = Channel.new('reply-' .. tostring(x))

  local client = ch:put({ x = x, reply = reply }):and_then(function()
    return reply:get()
  end)

  local leader = ch:get():and_then(function(m2)
    return ch:get():and_then(function(m3)
      return m2.reply:put(pair(m3.x, x)):and_then(function()
        return m3.reply:put(pair(x, m2.x)):and_then(function()
          return Op.always(pair(m2.x, m3.x))
        end)
      end)
    end)
  end)

  return Op.choice(client, leader)
end

local function demo_triple_swap()
  print('--- demo: triple swap ---')
  local rt = Runtime.new()
  local ch = Channel.new('triple')
  local results = {}

  for i = 1, 3 do
    local x = 10 + i
    rt:spawn(function()
      local got = Op.perform(triple_swap_op(ch, x))
      results[x] = got
      print(string.format('swapper %d got {%d,%d}', x, got[1], got[2]))
    end, 'swapper-' .. tostring(x))
  end

  rt:run()

  local checksum = 0
  for x, got in pairs(results) do checksum = checksum + x + got[1] + got[2] end
  print('triple swap checksum:', checksum)
  print()
end

-- --------------------------------------------------------------------------
-- Demo 2: Ledger transfer + close as one transaction.
-- --------------------------------------------------------------------------

local function demo_ledger()
  print('--- demo: ledger transfer + close commit event ---')
  local rt = Runtime.new()
  local ledger = Ledger.new({ ticket = 'extent:A' })

  rt:spawn(function()
    local ok = Op.perform(
      ledger:move('ticket', 'extent:A', 'extent:B'):and_then(function()
        return ledger:close('extent:A', 'moved-out'):and_then(function()
          return Op.emit({ tag = 'user.note', message = 'ledger tx body complete' }):and_then(function()
            return Op.always('transaction-result')
          end)
        end)
      end)
    )
    print('ledger transaction returned:', ok)
  end, 'ledger-tx')

  rt:run()

  print('ledger owner(ticket):', ledger.owners.ticket)
  print('ledger closed(extent:A):', ledger.closed['extent:A'])
  print()
end

-- Run the demos.
demo_triple_swap()
demo_ledger()
