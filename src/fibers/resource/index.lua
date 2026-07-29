local Facility = require('fibers.resource.authoring')
local perform = require('fibers.perform')

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
local next_append_id = 0
local ENTRY_RESULT = Facility.result.project(function(entry)
  return entry and { key = entry.key, rank = entry.rank, value = entry.value, seq = entry.seq }
end)

local function copy_entry(entry)
  return entry and { key = entry.key, rank = entry.rank, value = entry.value, seq = entry.seq } or nil
end

local function create(entries, name)
  local index = Facility.identity(setmetatable({ _initial_entries = {} }, Index), Kind, name)
  for i = 1, #entries do
    local entry, key = entries[i], entries[i].key or i
    index._initial_entries[key] =
      { key = key, rank = entry.rank or i, value = entry.value, seq = entry.seq or i }
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
  index._pop_first_op = Facility.op(
    index,
    Kind,
    Facility.select({
      location = index._location,
      order = 'min',
      result = ENTRY_RESULT,
    })
  )
  index._pop_last_op = Facility.op(
    index,
    Kind,
    Facility.select({
      location = index._location,
      order = 'max',
      result = ENTRY_RESULT,
    })
  )
  index._changed_descriptor = Facility.descriptor(index, Kind, 'version_wait', {
    location = index._location,
    bind = 'version',
  })
  return index
end

function Index.new(name)
  return create({}, name)
end

function Index.from(entries, name)
  return create(entries, name)
end

local function insert_program(index, key, rank, value, seq)
  local entry = { key = key, rank = rank, value = value, seq = seq or 0 }
  return Facility.claim({
    location = index._location,
    demand = 'down',
    query = { kind = 'predicate', predicate = 'map_absent', key = key },
    change = Facility.change.map_put(key, entry, 'insert'),
    result = Facility.result.boolean,
  })
end

function Index:insert_op(key, rank, value)
  if key == nil then
    error('index insert requires a key', 2)
  end
  if rank == nil then
    error('index insert requires a rank', 2)
  end
  return Facility.op(self, Kind, insert_program(self, key, rank, value, 0))
end

function Index:insert(key, rank, value)
  return perform(self:insert_op(key, rank, value))
end
function Index:insert_auto_op(rank, value)
  if rank == nil then
    error('index insert_auto requires a rank', 2)
  end
  next_append_id = next_append_id + 1
  local key = self._fibers_id .. ':auto:' .. tostring(next_append_id)
  return Facility.op(self, Kind, insert_program(self, key, rank, value, next_append_id))
end

function Index:insert_auto(rank, value)
  return perform(self:insert_auto_op(rank, value))
end
function Index:append_op(value)
  next_append_id = next_append_id + 1
  local key = self._fibers_id .. ':append:' .. tostring(next_append_id)
  return Facility.op(self, Kind, insert_program(self, key, math.huge, value, next_append_id))
end

function Index:append(value)
  return perform(self:append_op(value))
end
function Index:remove_op(key)
  if key == nil then
    error('index remove requires a key', 2)
  end
  return Facility.op(
    self,
    Kind,
    Facility.claim({
      location = self._location,
      demand = 'up',
      query = { kind = 'predicate', predicate = 'map_present', key = key },
      change = Facility.change.map_remove(key),
      result = Facility.result.boolean,
    })
  )
end

function Index:remove(key)
  return perform(self:remove_op(key))
end
function Index:pop_first_op()
  return self._pop_first_op
end

function Index:pop_first()
  return perform(self:pop_first_op())
end
function Index:pop_last_op()
  return self._pop_last_op
end

function Index:pop_last()
  return perform(self:pop_last_op())
end
function Index:changed_op(version)
  return Facility.occurrence(self._changed_descriptor, version)
end

function Index:changed(version)
  return perform(self:changed_op(version))
end
Index.Kind = Kind
return Index
