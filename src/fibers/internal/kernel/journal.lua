-- Speculative journal: rollback plus hierarchical transactional state.

local Algebra = require('fibers.internal.kernel.algebra')

local Journal = { ABSENT = Algebra.ABSENT }
Journal.__index = Journal
local NIL = {}

function Journal.new()
  return setmetatable({ current = 0, next_mark = 0, observed = {}, writers = {}, segments = {} }, Journal)
end

function Journal:mark()
  if not self.entries then
    self.entries = {}
    self.marks = {}
    self.parents = {}
  end
  local entries = self.entries
  local mark = self.next_mark + 1
  self.next_mark = mark
  self.marks[mark] = #entries
  self.parents[mark] = self.current
  self.current = mark
  return mark
end

local function record(self, kind, target, key, old, old_stamp)
  local entries = self.entries
  local n = #entries
  entries[n + 1] = kind
  entries[n + 2] = target
  entries[n + 3] = key
  entries[n + 4] = old == nil and NIL or old
  entries[n + 5] = old_stamp or 0
end

function Journal:set(target, key, value)
  if target[key] == value then
    return
  end
  local mark = self.current
  if mark == 0 then
    target[key] = value
    return
  end
  local all_stamps = self.field_stamps
  if not all_stamps then
    all_stamps = {}
    self.field_stamps = all_stamps
  end
  local stamps = all_stamps[target]
  if not stamps then
    stamps = {}
    all_stamps[target] = stamps
  end
  local previous = stamps[key] or 0
  if previous ~= mark then
    record(self, 1, target, key, target[key], previous)
    stamps[key] = mark
  end
  target[key] = value
end

function Journal:push(target, value)
  local mark = self.current
  if mark == 0 then
    target[#target + 1] = value
    return
  end
  local stamps = self.push_stamps
  if not stamps then
    stamps = {}
    self.push_stamps = stamps
  end
  local previous = stamps[target] or 0
  if previous ~= mark then
    record(self, 2, target, false, #target, previous)
    stamps[target] = mark
  end
  target[#target + 1] = value
end

function Journal:size()
  return self.entries and (#self.entries / 5) or 0
end

function Journal:accept(mark)
  local entries = self.entries
  local stop = self.marks[mark]
  local parent = self.parents[mark] or 0
  if self.current ~= mark then
    error('journal marks must be accepted in stack order', 2)
  end

  for n = stop + 5, #entries, 5 do
    local kind = entries[n - 4]
    local target = entries[n - 3]
    local key = entries[n - 2]
    if kind == 1 then
      local stamps = self.field_stamps and self.field_stamps[target]
      if stamps and stamps[key] == mark then
        stamps[key] = parent ~= 0 and parent or nil
      end
    else
      if self.push_stamps and self.push_stamps[target] == mark then
        self.push_stamps[target] = parent ~= 0 and parent or nil
      end
    end
  end

  if parent == 0 then
    for n = #entries, stop + 1, -1 do entries[n] = nil end
  end
  self.current = parent
  self.marks[mark], self.parents[mark] = nil, nil
end

function Journal:rollback(mark)
  local entries = self.entries
  local stop = self.marks[mark]
  for n = #entries, stop + 1, -5 do
    local kind = entries[n - 4]
    local target = entries[n - 3]
    local key = entries[n - 2]
    local old = entries[n - 1]
    if old == NIL then old = nil end
    local old_stamp = entries[n]
    if kind == 1 then
      target[key] = old
      local stamps = self.field_stamps and self.field_stamps[target]
      if stamps then stamps[key] = old_stamp ~= 0 and old_stamp or nil end
    else
      for i = #target, old + 1, -1 do target[i] = nil end
      if self.push_stamps then self.push_stamps[target] = old_stamp ~= 0 and old_stamp or nil end
    end
    entries[n - 4], entries[n - 3], entries[n - 2], entries[n - 1], entries[n] = nil, nil, nil, nil, nil
  end
  self.current = self.parents[mark] or 0
  self.marks[mark], self.parents[mark] = nil, nil
  self.writers = {}
end

function Journal:reset()
  self.current, self.next_mark = 0, 0
  self.entries, self.marks, self.parents = nil, nil, nil
  self.field_stamps, self.push_stamps = nil, nil
  self.observed, self.writers, self.segments = nil, nil, nil
end


function Journal.new_location(opts)
  opts = opts or {}
  local algebra = Algebra.get(assert(opts.algebra, 'location algebra is required'))
  local location = {
    algebra = algebra,
    domain = opts.domain or 'plain',
    value = opts.value,
    version = opts.version or 0,
    owner = opts.owner,
    key = opts.key,
    clone_value = opts.clone_value,
    put_equal = opts.put_equal == true,
    remove_idempotent = opts.remove_idempotent ~= false,
  }
  return location
end

function Journal:new_segment(root, parent, group, lane)
  local segment = {
    journal = self,
    parent = parent,
    depth = parent and parent.depth + 1 or 0,
    group = group,
    lane = lane,
    values = {}, -- materialised values for locally written locations
    delta = {},
    root = root,
    retired = false,
  }
  self.segments[#self.segments + 1] = segment
  return segment
end

function Journal.observe(segment, location)
  local journal = segment.journal
  local observed = journal.observed
  if observed[location] == nil then
    journal:set(observed, location, location.version or 0)
  end
end

local function inherited_value(segment, location)
  local cached = segment.values[location]
  if cached ~= nil then return cached end
  if segment.parent then return Journal.read(segment.parent, location) end
  return location.value
end

function Journal.read(segment, location)
  Journal.observe(segment, location)
  local value = inherited_value(segment, location)
  local summary = segment.delta[location]
  if summary and segment.values[location] == nil then
    value = Algebra.apply(location, value, summary)
  end
  return value
end

local function stage_summary(segment, location, patch)
  local journal = segment.journal
  local old = segment.delta[location]
  local summary = Algebra.stage(location, old, patch, journal)
  if summary ~= old then journal:set(segment.delta, location, summary) end
end

function Journal.stage(segment, location, patch)
  local journal = segment.journal
  local value = Journal.read(segment, location)
  stage_summary(segment, location, patch)
  journal:set(segment.values, location, Algebra.apply(location, value, patch))
  journal.writers[location] = nil
end

local function writers_for(journal, location)
  local writers = journal.writers[location]
  if writers then return writers end
  writers = {}
  for i = 1, #journal.segments do
    local segment = journal.segments[i]
    if not segment.retired and rawget(segment.delta, location) then writers[#writers + 1] = segment end
  end
  journal.writers[location] = writers
  return writers
end

local function relation(left, right)
  if left.root ~= right.root then return 'external' end
  if left == right then return nil end
  local a, b, da, db = left, right, left.depth, right.depth
  while da > db do a, da = a.parent, da - 1 end
  while db > da do b, db = b.parent, db - 1 end
  if a == b then return nil end
  while a and b and a.parent ~= b.parent do a, b = a.parent, b.parent end
  if not a or not b or a.group ~= b.group or a.lane == b.lane then return nil end
  return a.group.mode == 'interacting' and 'interacting' or 'independent'
end

Journal.relation = relation

local function visible_patch(location, patch, relation, orientation)
  if relation == 'external' or relation == 'interacting' then
    return patch
  elseif relation == 'independent' then
    return Algebra.constraint(location, patch, orientation)
  end
end

function Journal.project(task, location, orientation)
  local own = task.segment
  local journal = own.journal
  local value = Journal.read(own, location)
  local combined
  local writers = writers_for(journal, location)
  for i = 1, #writers do
    local segment = writers[i]
    local patch = segment.delta[location]
    if segment ~= own and not segment.retired and patch then
      local relation = relation(own, segment)
      local visible = visible_patch(location, patch, relation, orientation)
      if visible then
        local mode = relation == 'interacting' and 'interacting'
          or relation == 'external' and 'external'
          or 'independent'
        combined = Algebra.join(location, combined, visible, mode)
        if not combined then
          return nil, false
        end
      end
    end
  end
  if combined then
    value = Algebra.apply(location, value, combined)
  end
  return value, true
end

function Journal.project_machine(task, location, succeeds, accepts_supply)
  local own = task.segment
  local journal = own.journal
  local value = Journal.read(own, location)
  local steps = {}
  local writers = writers_for(journal, location)
  for i = 1, #writers do
    local segment = writers[i]
    local patch = segment.delta[location]
    if segment ~= own and not segment.retired and patch then
      local relation = relation(own, segment)
      if relation == 'external' or relation == 'interacting' or relation == 'independent' then
        Algebra.serialise(location, patch, relation, steps)
      end
    end
  end
  table.sort(steps, function(left, right)
    return left.serial < right.serial
  end)
  for i = 1, #steps do
    local step = steps[i]
    local restricted = step.relation == 'independent' or not accepts_supply
    if restricted then
      local before = succeeds(value)
      local after = succeeds(step.value)
      if before or not after then
        value = step.value
      end
    else
      value = step.value
    end
  end
  return value
end

local function merge_segments(segments, mode)
  local writes = {}
  for i = 1, #segments do
    for location, patch in pairs(segments[i].delta) do
      local merged = Algebra.join(location, writes[location], patch, mode)
      if not merged then return nil end
      writes[location] = merged
    end
  end
  return writes
end

function Journal.join_segments(parent, children, mode)
  local writes = merge_segments(children, mode)
  if not writes then return false end
  for location, patch in pairs(writes) do
    Journal.stage(parent, location, patch)
  end
  for i = 1, #children do
    parent.journal:set(children[i], 'retired', true)
  end
  return true
end

function Journal:collect_candidate(root_segments)
  local writes = merge_segments(root_segments, 'external')
  if not writes then return nil, nil, false end
  return self.observed, writes, true
end

function Journal.validate(observations)
  for location, version in pairs(observations or {}) do
    if (location.version or 0) ~= version then
      return false
    end
  end
  return true
end

function Journal.commit(writes)
  local prepared = {}
  for location, summary in pairs(writes or {}) do
    local n = #prepared
    prepared[n + 1] = location
    prepared[n + 2] = Algebra.apply(location, location.value, summary)
    prepared[n + 3] = (location.version or 0) + 1
  end
  for i = 1, #prepared, 3 do
    prepared[i].value = prepared[i + 1]
    prepared[i].version = prepared[i + 2]
  end
end


return Journal
