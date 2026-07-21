-- Representation-neutral rollback journal for the ledger machine.

local Trail = {}
Trail.__index = Trail

function Trail.new(stats, plan)
  return setmetatable({
    n = 0,
    kinds = {},
    targets = {},
    keys = {},
    olds = {},
    old_marks = {},
    mark_ns = {},
    mark_parents = {},
    set_marks = {},
    push_marks = {},
    stats = stats,
    plan = plan,
    next_mark = 0,
    current_mark = 0,
  }, Trail)
end

function Trail:mark()
  local mark = self.next_mark + 1
  self.next_mark = mark
  self.mark_ns[mark] = self.n
  self.mark_parents[mark] = self.current_mark
  self.current_mark = mark
  return mark
end

local function add_entry(self, kind, target, key, old, old_mark)
  local n = self.n + 1
  self.n = n
  self.kinds[n], self.targets[n], self.keys[n], self.olds[n] = kind, target, key, old
  self.old_marks[n] = old_mark or 0
  if self.stats then
    self.stats.trail_entries = (self.stats.trail_entries or 0) + 1
  end
  local plan = self.plan
  if plan then
    plan.trail_entries = plan.trail_entries + 1
    if n > plan.max_trail then
      plan.max_trail = n
    end
  end
end

function Trail:set(target, key, value)
  if target[key] == value then
    return
  end
  -- Mutations made before the first speculative checkpoint are the plan's
  -- base state.  They can never be reached by rollback, so journalling them is
  -- pure overhead on deterministic and forced paths.
  local mark = self.current_mark
  if mark == 0 then
    target[key] = value
    return
  end

  -- A branch checkpoint only needs the value observed before its first write
  -- to one field.  Subsequent writes to that field in the same branch are
  -- restored by the same journal entry.  Nested marks retain their own first
  -- write and restore the parent's stamp when rolled back.
  local marks = self.set_marks[target]
  if not marks then
    marks = {}
    self.set_marks[target] = marks
  end
  local old_mark = marks[key] or 0
  if old_mark ~= mark then
    add_entry(self, 1, target, key, target[key], old_mark)
    marks[key] = mark
  else
    local plan = self.plan
    if plan then
      plan.trail_set_coalesced = (plan.trail_set_coalesced or 0) + 1
    end
  end
  target[key] = value
end

function Trail:push(target, value)
  local mark = self.current_mark
  if mark == 0 then
    target[#target + 1] = value
    return
  end

  -- As with field writes, one length snapshot per array and checkpoint is
  -- sufficient to undo any number of pushes made in that branch.
  local old_mark = self.push_marks[target] or 0
  if old_mark ~= mark then
    add_entry(self, 2, target, nil, #target, old_mark)
    self.push_marks[target] = mark
  else
    local plan = self.plan
    if plan then
      plan.trail_push_coalesced = (plan.trail_push_coalesced or 0) + 1
    end
  end
  target[#target + 1] = value
end

function Trail:rollback(mark)
  local mark_n = self.mark_ns[mark]
  local removed = self.n - mark_n
  for i = self.n, mark_n + 1, -1 do
    local kind, target, key, old = self.kinds[i], self.targets[i], self.keys[i], self.olds[i]
    local old_mark = self.old_marks[i] or 0
    if kind == 1 then
      target[key] = old
      local marks = self.set_marks[target]
      if marks then
        marks[key] = old_mark ~= 0 and old_mark or nil
      end
    elseif kind == 2 then
      for j = #target, old + 1, -1 do
        target[j] = nil
      end
      self.push_marks[target] = old_mark ~= 0 and old_mark or nil
    else
      error('unknown trail entry: ' .. tostring(kind), 0)
    end
    self.kinds[i], self.targets[i], self.keys[i], self.olds[i], self.old_marks[i] = nil, nil, nil, nil, nil
  end
  self.n = mark_n
  self.current_mark = self.mark_parents[mark] or 0
  self.mark_ns[mark], self.mark_parents[mark] = nil, nil
  if self.stats then
    self.stats.rollbacks = (self.stats.rollbacks or 0) + 1
  end
  local plan = self.plan
  if plan then
    plan.rollbacks = plan.rollbacks + 1
    plan.rollback_entries = plan.rollback_entries + removed
  end
  if self.on_rollback then
    self.on_rollback(self.rollback_context)
  end
end

function Trail:begin(stats, plan)
  if self.n ~= 0 or self.current_mark ~= 0 then
    error('cannot begin a search with a non-empty trail', 2)
  end
  self.stats = stats
  self.plan = plan
end

function Trail:reset(stats, plan)
  for i = self.n, 1, -1 do
    self.kinds[i], self.targets[i], self.keys[i], self.olds[i], self.old_marks[i] = nil, nil, nil, nil, nil
  end
  self.n = 0
  for i = self.next_mark, 1, -1 do
    self.mark_ns[i], self.mark_parents[i] = nil, nil
  end
  self.next_mark, self.current_mark = 0, 0
  self.set_marks, self.push_marks = {}, {}
  if stats ~= nil then
    self.stats = stats
  end
  if plan ~= nil or self.plan ~= nil then
    self.plan = plan
  end
end

return Trail
