local Facility = require('fibers.resource.authoring')
local Extreme = require('fibers.resource.extreme')
local Direct = require('fibers.internal.direct')

local Index = {}
Index.__index = function(self, key)
  if key == 'entries' then
    return self._location and self._location.value or self._initial_entries
  end
  if key == 'version' then
    return self._location and self._location.version or 0
  end
  return Index[key]
end
local Kind = Facility.kind('index')
local ENTRY_RESULT = Facility.result.project(function(entry)
  return entry and { key = entry.key, rank = entry.rank, value = entry.value, seq = entry.seq }
end)

local function copy_entry(entry)
  return entry and { key = entry.key, rank = entry.rank, value = entry.value, seq = entry.seq } or nil
end

local function create(entries)
  local index = Facility.identity(setmetatable({ _initial_entries = {}, _next_seq = 0 }, Index), Kind)
  local order = {}
  for i = 1, #entries do
    local entry, key = entries[i], entries[i].key or i
    local rank = entry.rank or i
    local seq = entry.seq
    if seq == nil then seq = index._next_seq + 1 end
    if rank == nil or rank ~= rank then
      error('index entry rank is required', 3)
    end
    if type(seq) ~= 'number' or seq ~= seq then
      error('index entry sequence must be a number', 3)
    end
    local by_seq = order[rank]
    if not by_seq then by_seq = {}; order[rank] = by_seq end
    if by_seq[seq] then
      error('index entries require unique (rank, sequence) pairs', 3)
    end
    by_seq[seq] = true
    if seq > index._next_seq then index._next_seq = seq end
    index._initial_entries[key] = { key = key, rank = rank, value = entry.value, seq = seq }
  end
  index._location = Facility.location(index, 'entries', {
    algebra = 'finite_map',
    domain = 'finite_map',
    value = index._initial_entries,
    clone_value = copy_entry,
    put_equal = false,
    remove_idempotent = true,
  })
  index._initial_entries = nil
  index._pop_first_op = Facility.op(Extreme.spec({
      location = index._location,
      order = 'min',
      result = ENTRY_RESULT,
    })
  )
  index._pop_last_op = Facility.op(Extreme.spec({
      location = index._location,
      order = 'max',
      result = ENTRY_RESULT,
    })
  )
  index._changed_spec = Facility.version_wait(index._location, index)
  return index
end

function Index.new()
  return create({})
end

function Index.from(entries)
  return create(entries)
end

local function next_sequence(index)
  index._next_seq = index._next_seq + 1
  return index._next_seq
end

local function insert_leaf(index, key, rank, value, seq)
  local entry = { key = key, rank = rank, value = value, seq = seq }
  return Facility.rule.change({
    location = index._location,
    resource = index,
    demand = 'down',
    visibility = 'together',
    supply = 'up',
    step = function(entries)
      if entries[key] ~= nil then return nil end
      return Facility.outcome(Facility.patch.map_put(key, entry, 'insert'), true)
    end,
  })
end

function Index:insert_op(key, rank, value)
  if key == nil then
    error('index insert requires a key', 2)
  end
  if rank == nil or rank ~= rank then
    error('index insert requires a rank', 2)
  end
  return Facility.op(insert_leaf(self, key, rank, value, next_sequence(self)))
end

function Index:insert_auto_op(rank, value)
  if rank == nil or rank ~= rank then
    error('index insert_auto requires a rank', 2)
  end
  local seq = next_sequence(self)
  local key = self._fibers_id .. ':auto:' .. tostring(seq)
  return Facility.op(insert_leaf(self, key, rank, value, seq))
end

function Index:append_op(value)
  local seq = next_sequence(self)
  local key = self._fibers_id .. ':append:' .. tostring(seq)
  return Facility.op(insert_leaf(self, key, math.huge, value, seq))
end

function Index:remove_op(key)
  if key == nil then
    error('index remove requires a key', 2)
  end
  return Facility.op(Facility.rule.change({
      location = self._location,
      resource = self,
      demand = 'up',
      visibility = 'together',
      supply = 'down',
      step = function(entries)
        if entries[key] == nil then return nil end
        return Facility.outcome(Facility.patch.map_remove(key), true)
      end,
    })
  )
end

function Index:pop_first_op()
  return self._pop_first_op
end

function Index:pop_last_op()
  return self._pop_last_op
end

function Index:changed_op(version)
  return Facility.bind(self._changed_spec, version)
end

Index.Kind = Kind
Direct.install(Index, { 'insert', 'insert_auto', 'append', 'remove', 'pop_first', 'pop_last', 'changed' })

return Index
