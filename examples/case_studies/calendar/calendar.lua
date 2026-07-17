local Op = require('fibers.op')
local IR = require('fibers.internal.kernel.ir')
local Store = require('fibers.internal.kernel.store')

local Calendar = {}
Calendar.__index = Calendar
local Kind = { name = 'calendar' }
local next_calendar_id = 0

local function copy_array(xs)
  local out = {}
  for i = 1, #(xs or {}) do
    out[i] = xs[i]
  end
  return out
end
local function copy_resources(xs)
  local out = copy_array(xs)
  table.sort(out, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return out
end
local function clone_record(r)
  return r
      and {
        id = r.id,
        start = r.start,
        finish = r.finish,
        resources = copy_resources(r.resources),
        payload = r.payload,
      }
    or nil
end
local function overlaps(a0, a1, b0, b1)
  return a0 < b1 and b0 < a1
end
local function resource_set(xs)
  local out = {}
  for i = 1, #xs do
    out[xs[i]] = true
  end
  return out
end
local function shares(wanted, xs)
  for i = 1, #xs do
    if wanted[xs[i]] then
      return true
    end
  end
  return false
end

-- Persistent id map used only for cancellation lookup.
local TOMBSTONE = {}
local function map_new(parent)
  return { parent = parent, delta = {}, depth = parent and parent.depth + 1 or 0 }
end
local function map_get(m, key)
  while m do
    local v = m.delta[key]
    if v ~= nil then
      return v == TOMBSTONE and nil or v
    end
    m = m.parent
  end
end
local function map_set(parent, key, value)
  if parent and parent.depth > 24 then
    local flat, chain = {}, {}
    local m = parent
    while m do
      chain[#chain + 1] = m
      m = m.parent
    end
    for i = #chain, 1, -1 do
      for k, v in pairs(chain[i].delta) do
        flat[k] = v
      end
    end
    parent = { parent = nil, delta = flat, depth = 0 }
  end
  local out = map_new(parent)
  out.delta[key] = value == nil and TOMBSTONE or value
  return out
end

-- Immutable interval treap.  Each update copies only the search path.
local function priority(id)
  return (id * 1103515245 + 12345) % 2147483647
end
local function max3(a, b, c)
  return math.max(a or -math.huge, b or -math.huge, c or -math.huge)
end
local function make_node(record, left, right)
  return {
    record = record,
    key_start = record.start,
    key_id = record.id,
    priority = priority(record.id),
    left = left,
    right = right,
    max_finish = max3(record.finish, left and left.max_finish, right and right.max_finish),
  }
end
local function before(a_start, a_id, b_start, b_id)
  return a_start < b_start or (a_start == b_start and a_id < b_id)
end
local function rotate_right(n)
  local l = n.left
  return make_node(l.record, l.left, make_node(n.record, l.right, n.right))
end
local function rotate_left(n)
  local r = n.right
  return make_node(r.record, make_node(n.record, n.left, r.left), r.right)
end
local function insert(root, record)
  if not root then
    return make_node(record)
  end
  local out
  if before(record.start, record.id, root.key_start, root.key_id) then
    out = make_node(root.record, insert(root.left, record), root.right)
    if out.left.priority < out.priority then
      out = rotate_right(out)
    end
  else
    out = make_node(root.record, root.left, insert(root.right, record))
    if out.right.priority < out.priority then
      out = rotate_left(out)
    end
  end
  return out
end
local function merge_trees(a, b)
  if not a then
    return b
  elseif not b then
    return a
  end
  if a.priority < b.priority then
    return make_node(a.record, a.left, merge_trees(a.right, b))
  end
  return make_node(b.record, merge_trees(a, b.left), b.right)
end
local function remove(root, start, id)
  if not root then
    return nil
  end
  if root.key_start == start and root.key_id == id then
    return merge_trees(root.left, root.right)
  end
  if before(start, id, root.key_start, root.key_id) then
    return make_node(root.record, remove(root.left, start, id), root.right)
  end
  return make_node(root.record, root.left, remove(root.right, start, id))
end
local function each(root, fn)
  if root then
    each(root.left, fn)
    fn(root.record)
    each(root.right, fn)
  end
end

local function conflict_node(root, wanted, start, finish, ignore_id)
  if not root or root.max_finish <= start then
    return false
  end
  if conflict_node(root.left, wanted, start, finish, ignore_id) then
    return true
  end
  local r = root.record
  if
    r.start < finish
    and r.id ~= ignore_id
    and overlaps(start, finish, r.start, r.finish)
    and shares(wanted, r.resources)
  then
    return true
  end
  if root.key_start >= finish then
    return false
  end
  return conflict_node(root.right, wanted, start, finish, ignore_id)
end
local function conflict(state, resources, start, finish, ignore_id)
  return conflict_node(state.root, resource_set(resources), start, finish, ignore_id)
end
local function slot_candidates(state, spec)
  local starts, seen = {}, {}
  local function add(x)
    if type(x) == 'number' and x >= spec.earliest and x + spec.duration <= spec.latest and not seen[x] then
      seen[x] = true
      starts[#starts + 1] = x
    end
  end
  if spec.starts then
    for i = 1, #spec.starts do
      add(spec.starts[i])
    end
  else
    add(spec.earliest)
    local wanted = resource_set(spec.resources)
    each(state.root, function(r)
      if shares(wanted, r.resources) then
        add(r.finish)
      end
    end)
  end
  table.sort(starts)
  if spec.preference == 'latest' then
    local rev = {}
    for i = #starts, 1, -1 do
      rev[#rev + 1] = starts[i]
    end
    return rev
  end
  return starts
end

function Calendar.new(initial, name)
  next_calendar_id = next_calendar_id + 1
  local state = { next_id = 0, root = nil, by_id = map_new(nil) }
  for i = 1, #(initial or {}) do
    local r = initial[i]
    state.next_id = state.next_id + 1
    local id = r.id or state.next_id
    if type(id) == 'number' and id > state.next_id then
      state.next_id = id
    end
    local record = {
      id = id,
      start = assert(r.start),
      finish = assert(r.finish),
      resources = copy_resources(assert(r.resources)),
      payload = r.payload,
    }
    state.root = insert(state.root, record)
    state.by_id = map_set(state.by_id, id, record)
  end
  local calendar = setmetatable({
    name = name or ('calendar-' .. next_calendar_id),
    _fibers_id = 'calendar-' .. next_calendar_id,
    _fibers_kind = Kind,
    _state = state,
    version = 0,
  }, Calendar)
  calendar._location = Store.new_location({
    name = calendar.name .. ':schedule',
    merge = 'machine',
    domain = 'plain',
    value = state,
    owner = calendar,
    apply = function(v, loc)
      calendar._state, calendar.version = v, loc.version
    end,
  })
  return calendar
end

local function validate_spec(spec)
  assert(type(spec) == 'table', 'calendar reservation expects a table')
  assert(type(spec.resources) == 'table' and #spec.resources > 0, 'calendar reservation requires resources')
  assert(
    type(spec.earliest) == 'number' and type(spec.latest) == 'number',
    'calendar reservation requires earliest and latest'
  )
  assert(
    type(spec.duration) == 'number' and spec.duration > 0,
    'calendar reservation requires positive duration'
  )
  assert(spec.earliest + spec.duration <= spec.latest, 'calendar reservation window is too small')
end
local function slot_cursor(state, spec, writes)
  local starts, i = slot_candidates(state, spec), 0
  return {
    next = function()
      while true do
        i = i + 1
        local start = starts[i]
        if start == nil then
          return nil
        end
        local finish = start + spec.duration
        if not conflict(state, spec.resources, start, finish) then
          local record = {
            id = nil,
            start = start,
            finish = finish,
            resources = copy_resources(spec.resources),
            payload = spec.payload,
          }
          if writes then
            record.id = state.next_id + 1
            local successor = {
              next_id = record.id,
              root = insert(state.root, record),
              by_id = map_set(state.by_id, record.id, record),
            }
            return { value = successor, result = Op._pack(clone_record(record)), writes = true }
          end
          return { result = Op._pack(clone_record(record)), writes = false }
        end
      end
    end,
  }
end
local function frozen_spec(spec)
  return {
    resources = copy_resources(spec.resources),
    earliest = spec.earliest,
    latest = spec.latest,
    duration = spec.duration,
    starts = spec.starts and copy_array(spec.starts) or nil,
    preference = spec.preference or 'earliest',
    payload = spec.payload,
  }
end
function Calendar:reserve_op(spec)
  validate_spec(spec)
  local frozen = frozen_spec(spec)
  return Op._resource(
    self,
    Kind,
    IR.witness_transition({
      location = self._location,
      group = self._location,
      supply = 'interacting',
      cursor = function(state)
        return slot_cursor(state, frozen, true)
      end,
    })
  )
end
function Calendar:find_op(spec)
  validate_spec(spec)
  local frozen = frozen_spec(spec)
  return Op._resource(
    self,
    Kind,
    IR.witness_transition({
      location = self._location,
      group = self._location,
      supply = 'interacting',
      cursor = function(state)
        return slot_cursor(state, frozen, false)
      end,
    })
  )
end
function Calendar:reserve_at_op(resources, start, finish, payload)
  return self:reserve_op({
    resources = resources,
    earliest = start,
    latest = finish,
    duration = finish - start,
    starts = { start },
    payload = payload,
  })
end
function Calendar:cancel_op(id)
  return Op._resource(
    self,
    Kind,
    IR.witness_transition({
      location = self._location,
      group = self._location,
      supply = 'interacting',
      cursor = function(state)
        local done = false
        return {
          next = function()
            if done then
              return nil
            end
            done = true
            local old = map_get(state.by_id, id)
            if not old then
              return nil
            end
            local successor = {
              next_id = state.next_id,
              root = remove(state.root, old.start, old.id),
              by_id = map_set(state.by_id, id, nil),
            }
            return { value = successor, result = Op._pack(clone_record(old)), writes = true }
          end,
        }
      end,
    })
  )
end
function Calendar:snapshot_op()
  return Op._resource(
    self,
    Kind,
    IR.witness_transition({
      location = self._location,
      supply = 'none',
      cursor = function(state)
        local done = false
        return {
          next = function()
            if done then
              return nil
            end
            done = true
            local out = {}
            each(state.root, function(r)
              out[r.id] = clone_record(r)
            end)
            return { writes = false, result = Op._pack(out) }
          end,
        }
      end,
    })
  )
end
function Calendar:snapshot()
  local out = {}
  each(self._state.root, function(r)
    out[r.id] = clone_record(r)
  end)
  return out
end
Calendar.Kind = Kind
return Calendar
