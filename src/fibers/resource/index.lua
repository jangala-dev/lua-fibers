local Facility = require('fibers.resource.authoring')
local Direct = require('fibers.internal.direct')

local Index = {}
Index.__index = Index
local Kind = Facility.kind('index')

local function copy_entry(entry)
  return entry and { key = entry.key, rank = entry.rank, value = entry.value, seq = entry.seq } or nil
end

local function insert(entries, request, context)
  local key = request.key
  if key ~= nil and entries[key] ~= nil then return nil end
  local serial = (context and context.serial) or 1
  local seq = request.base + request.location.version + serial / (serial + 1)
  if request.prefix then key = request.prefix .. tostring(seq) end
  if entries[key] ~= nil then return nil end
  local entry = { key = key, rank = request.rank, value = request.value, seq = seq }
  return Facility.outcome(Facility.patch.map_put(key, entry, 'insert'), true)
end

local function remove(entries, key)
  if entries[key] == nil then return nil end
  return Facility.outcome(Facility.patch.map_remove(key), true)
end

local function pop(entries, maximum)
  local best_key, best
  for key, entry in pairs(entries) do
    if not best then
      best_key, best = key, entry
    else
      local rank, best_rank = entry.rank, best.rank
      local better = rank ~= best_rank
        and (maximum and rank > best_rank or not maximum and rank < best_rank)
      if rank == best_rank then
        local seq, best_seq = entry.seq, best.seq
        if seq == best_seq then error('index entries require unique (rank, sequence) pairs', 2) end
        better = maximum and seq > best_seq or not maximum and seq < best_seq
      end
      if better then best_key, best = key, entry end
    end
  end
  if not best then return nil end
  return Facility.outcome(Facility.patch.map_take(best_key), copy_entry(best))
end

local function create(entries)
  local index = Facility.identity(setmetatable({}, Index), Kind)
  local initial, order, maximum = {}, {}, 0
  for i = 1, #entries do
    local entry, key = entries[i], entries[i].key or i
    local rank = entry.rank or i
    local seq = entry.seq
    if seq == nil then seq = maximum + 1 end
    if rank == nil or rank ~= rank then error('index entry rank is required', 3) end
    if type(seq) ~= 'number' or seq ~= seq then error('index entry sequence must be a number', 3) end
    local by_seq = order[rank]
    if not by_seq then by_seq = {}; order[rank] = by_seq end
    if by_seq[seq] then error('index entries require unique (rank, sequence) pairs', 3) end
    by_seq[seq] = true
    maximum = math.max(maximum, seq)
    initial[key] = { key = key, rank = rank, value = entry.value, seq = seq }
  end
  index._location = Facility.location(index, {
    algebra = 'finite_map', domain = 'finite_map', value = initial,
    clone_value = copy_entry, put_equal = false, remove_idempotent = true,
  })
  index._sequence_base = maximum
  return index
end

function Index.new() return create({}) end
function Index.from(entries) return create(entries) end

local function change_spec(index, field, demand, supply, step)
  local spec = index[field]
  if not spec then
    spec = Facility.rule.change({
      location = index._location, resource = index, demand = demand,
      visibility = 'together', supply = supply, step = step,
    })
    index[field] = spec
  end
  return spec
end

local function pop_op(index, field, maximum)
  local op = index[field]
  if op then return op end
  local spec = index._pop_spec
  if not spec then
    spec = Facility.rule.change({
      location = index._location, demand = 'up', visibility = 'together', supply = 'down', step = pop,
    })
    index._pop_spec = spec
  end
  op = Facility.bind(spec, maximum)
  index[field] = op
  return op
end

function Index:insert_op(key, rank, value)
  if key == nil then error('index insert requires a key', 2) end
  if rank == nil or rank ~= rank then error('index insert requires a rank', 2) end
  return Facility.bind(change_spec(self, '_insert_spec', 'down', 'up', insert), {
    key = key, rank = rank, value = value, base = self._sequence_base, location = self._location,
  })
end

function Index:insert_auto_op(rank, value)
  if rank == nil or rank ~= rank then error('index insert_auto requires a rank', 2) end
  return Facility.bind(change_spec(self, '_insert_spec', 'down', 'up', insert), {
    prefix = self._fibers_id .. ':auto:', rank = rank, value = value, base = self._sequence_base, location = self._location,
  })
end

function Index:append_op(value)
  return Facility.bind(change_spec(self, '_insert_spec', 'down', 'up', insert), {
    prefix = self._fibers_id .. ':append:', rank = math.huge, value = value, base = self._sequence_base, location = self._location,
  })
end

function Index:remove_op(key)
  if key == nil then error('index remove requires a key', 2) end
  return Facility.bind(change_spec(self, '_remove_spec', 'up', 'down', remove), key)
end

function Index:pop_first_op() return pop_op(self, '_pop_first_op', false) end
function Index:pop_last_op() return pop_op(self, '_pop_last_op', true) end

Index.Kind = Kind
Direct.install(Index, { 'insert', 'insert_auto', 'append', 'remove', 'pop_first', 'pop_last' })

return Index
