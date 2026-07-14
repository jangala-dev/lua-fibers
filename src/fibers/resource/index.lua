local Op = require('fibers.op')
local Substrate = require('fibers.internal.kernel.store')
local Program = require('fibers.internal.kernel.ir')

local Index = {}
Index.__index = Index
local Kind = { name = 'index' }
local next_id, next_append_id = 0, 0

local function copy_entry(e)
  if not e then
    return nil
  end
  return { key = e.key, rank = e.rank, value = e.value, seq = e.seq }
end

function Index.new(entries, name)
  next_id = next_id + 1
  local index = setmetatable({
    name = name or ('index-' .. tostring(next_id)),
    _fibers_id = 'index-' .. tostring(next_id),
    _fibers_kind = Kind,
    entries = {},
    version = 0,
  }, Index)
  for i = 1, #(entries or {}) do
    local e = entries[i]
    local key = e.key or i
    index.entries[key] = { key = key, rank = e.rank or i, value = e.value, seq = e.seq or i }
  end
  index._location = Substrate.new_location({
    name = index.name .. ':entries',
    merge = 'finite_map',
    domain = 'finite_map',
    value = index.entries,
    owner = index,
    clone_value = copy_entry,
    put_equal = false,
    remove_idempotent = true,
    apply = function(v, loc)
      index.entries = v
      index.version = loc.version
    end,
  })
  return index
end

local function insert_program(index, key, rank, value, seq)
  local entry = { key = key, rank = rank, value = value, seq = seq or 0 }
  return Program.claim({
    location = index._location,
    group = index._location,
    orientation = 'down', -- absence is improved by deletion, not insertion
    predicate = 'map_absent',
    key = key,
    patch = {
      kind = 'finite_map',
      ops = { { op = 'put', key = key, value = entry, policy = 'insert' } },
    },
    result_kind = 'constant',
    result_value = true,
  })
end

function Index:insert_op(key, rank, value)
  if key == nil then
    error('index insert requires a key', 2)
  end
  if rank == nil then
    error('index insert requires a rank', 2)
  end
  return Op._resource(self, Kind, insert_program(self, key, rank, value, 0))
end

function Index:insert_auto_op(rank, value)
  if rank == nil then
    error('index insert_auto requires a rank', 2)
  end
  next_append_id = next_append_id + 1
  local seq = next_append_id
  local key = (self._fibers_id or 'index') .. ':auto:' .. tostring(seq)
  return Op._resource(self, Kind, insert_program(self, key, rank, value, seq))
end

function Index:append_op(value)
  next_append_id = next_append_id + 1
  local seq = next_append_id
  local key = (self._fibers_id or 'index') .. ':append:' .. tostring(seq)
  return Op._resource(self, Kind, insert_program(self, key, math.huge, value, seq))
end

function Index:remove_op(key)
  if key == nil then
    error('index remove requires a key', 2)
  end
  return Op._resource(
    self,
    Kind,
    Program.claim({
      location = self._location,
      group = self._location,
      orientation = 'up',
      predicate = 'map_present',
      key = key,
      patch = { kind = 'finite_map', ops = { { op = 'remove', key = key } } },
      result_kind = 'constant',
      result_value = true,
    })
  )
end

function Index:pop_first_op()
  return Op._resource(
    self,
    Kind,
    Program.select({
      location = self._location,
      group = self._location,
      order = 'min',
      orientation = 'up',
      result_kind = 'index_entry',
    })
  )
end

function Index:pop_last_op()
  return Op._resource(
    self,
    Kind,
    Program.select({
      location = self._location,
      group = self._location,
      order = 'max',
      orientation = 'up',
      result_kind = 'index_entry',
    })
  )
end

function Index:snapshot_op()
  return Op._resource(self, Kind, Program.snapshot(self, 'index'))
end

Index.Kind = Kind
return Index
