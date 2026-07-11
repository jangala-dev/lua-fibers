-- Ordered transactional index.
--
-- Index is a proof-premise based ordered collection.  Selection operations do
-- not hand provisional entries to Lua callbacks; instead they open premises and
-- the resolver allocates concrete entries from a projected transaction arena.
-- This lets ordinary and_then/map callbacks keep seeing ordinary Lua values.

local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Resolution = require('fibers.kernel.resources.resolution')
local Op = require('fibers.atoms.op')
local Validity = require('fibers.kernel.validity')
local Premise = require('fibers.kernel.premise_helpers')
local Presence = require('fibers.kernel.resources.presence_journal')

local OpPack = Op._pack

local Index = {}
Index.__index = Index

local IndexKind = { name = 'index' }
local next_id = 0
local next_append_id = 0

local function copy_entry(e)
  if not e then return nil end
  if type(e) ~= 'table' then return e end
  return { key = e.key, rank = e.rank, value = e.value, seq = e.seq }
end

local function clone_map(m)
  local out = {}
  for k, v in pairs(m or {}) do out[k] = copy_entry(v) or v end
  return out
end

local function ensure_rec(c, index, version)
  local rec = Resource.ensure(c, index, IndexKind)
  if rec.read == nil then rec.read = version or index.version or 0 end
  rec.inserts = rec.inserts or {}
  rec.removes = rec.removes or {}
  rec.selected_removes = rec.selected_removes or {}
  return rec
end

local function insert_record(c, index, key, rank, value, version, seq)
  local rec = ensure_rec(c, index, version)
  rec.removes[key] = nil
  rec.selected_removes[key] = nil
  rec.inserts[key] = { key = key, rank = rank, value = value, seq = seq }
  return rec
end

local function remove_record(c, index, key, version)
  local rec = ensure_rec(c, index, version)
  rec.inserts[key] = nil
  rec.selected_removes[key] = nil
  rec.removes[key] = true
  return rec
end

-- A selected remove is produced by a premise allocation.  Unlike an explicit
-- remove, it is allowed to cancel an insert made elsewhere in the same proof
-- world: insert + selected-pop means the entry was handed to the popper and no
-- final entry remains.  Explicit remove + insert remains conservative.
local function selected_remove_record(c, index, key, version)
  local rec = ensure_rec(c, index, version)
  if rec.inserts[key] then
    rec.inserts[key] = nil
  else
    rec.selected_removes[key] = true
  end
  return rec
end

local function merge_read(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
end

function IndexKind.clone(rec)
  return {
    kind = IndexKind,
    read = rec.read,
    inserts = clone_map(rec.inserts),
    removes = Premise.clone_bool_map(rec.removes),
    selected_removes = Premise.clone_bool_map(rec.selected_removes),
  }
end

local function normalise_empty_maps(rec)
  Presence.normalise(rec, 'inserts', false)
end

function IndexKind.merge_seq(dst, src)
  merge_read(dst, src)
  return Presence.merge_seq(dst, src, { field = 'inserts', clone = copy_entry, conflict = 'index-conflict' })
end

function IndexKind.merge_par(dst, src)
  merge_read(dst, src)
  return Presence.merge_par(dst, src, { field = 'inserts', clone = copy_entry, conflict = 'index-conflict', equal = function() return false end })
end

local function base_entries(index)
  local entries = {}
  for k, e in pairs(index.entries or {}) do entries[k] = copy_entry(e) end
  return entries
end

local function apply_record_to_entries(entries, rec)
  Presence.apply_to_entries(entries, rec, 'inserts', copy_entry)
end

local function projected_entries(index, records)
  local entries = base_entries(index)
  for i = 1, #(records or {}) do apply_record_to_entries(entries, records[i]) end
  return entries
end

local function sorted_entries(entries, reverse)
  local out = {}
  for _, e in pairs(entries or {}) do out[#out + 1] = copy_entry(e) end
  table.sort(out, function(a, b)
    if a.rank == b.rank then
      local as = a.seq or 0; local bs = b.seq or 0
      if as == bs then return tostring(a.key) < tostring(b.key) end
      return as < bs
    end
    return a.rank < b.rank
  end)
  if reverse then
    local rev = {}
    for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
    out = rev
  end
  return out
end

local function copy_constraint_record(rec)
  return {
    kind = IndexKind,
    read = rec and rec.read or nil,
    removes = Premise.clone_bool_map(rec and rec.removes),
    selected_removes = Premise.clone_bool_map(rec and rec.selected_removes),
    inserts = {},
  }
end

local function view_record_for_arena(view)
  local rec = Premise.record_from_view(view)
  if not rec then return nil end

  -- `all` lanes are independently satisfiable.  Sibling records from an
  -- `all` product may constrain allocation, but may not positively supply an
  -- entry that makes this lane's selection possible.  Tensor-internal sibling
  -- inserts are visible and may be consumed as handoff.
  if Premise.sibling_supply_hidden(view) then
    return copy_constraint_record(rec)
  end
  return rec
end

local function build_arena_from_views(index, views)
  local records = {}
  for i = 1, #(views or {}) do
    local rec = view_record_for_arena(views[i])
    if rec then records[#records + 1] = rec end
  end
  return projected_entries(index, records)
end

local function build_arena(index, records)
  return projected_entries(index, records)
end

function IndexKind.project(index, rec, query)
  if query == 'entries' then
    return projected_entries(index, rec and { rec } or nil), true
  elseif query == 'snapshot' then
    return { entries = projected_entries(index, rec and { rec } or nil), version = index.version or 0, _fibers_index_snapshot = true }, true
  end
  return nil, false
end

function IndexKind.prepare(index, rec, _resolve)
  if rec.read ~= nil and (index.version or 0) ~= rec.read then return nil, 'stale' end

  local projected = base_entries(index)
  for k in pairs(rec.removes or {}) do
    if not projected[k] then return nil, 'index-missing' end
    projected[k] = nil
  end
  for k in pairs(rec.selected_removes or {}) do
    if not projected[k] then return nil, 'index-missing' end
    projected[k] = nil
  end
  for k, e in pairs(rec.inserts or {}) do
    if projected[k] then return nil, 'index-duplicate' end
    projected[k] = copy_entry(e)
  end

  if not rec.inserts and not rec.removes and not rec.selected_removes then return nil, nil, true end
  return {
    kind = IndexKind,
    resource = index,
    inserts = clone_map(rec.inserts),
    removes = Premise.clone_bool_map(rec.removes),
    selected_removes = Premise.clone_bool_map(rec.selected_removes),
  }
end

function IndexKind.apply(prepared, _log)
  local index = prepared.resource
  local changed = false
  for k in pairs(prepared.removes or {}) do
    if index.entries[k] then index.entries[k] = nil; changed = true end
  end
  for k in pairs(prepared.selected_removes or {}) do
    if index.entries[k] then index.entries[k] = nil; changed = true end
  end
  for k, e in pairs(prepared.inserts or {}) do
    index.entries[k] = copy_entry(e); changed = true
  end
  if changed then
    index.version = (index.version or 0) + 1
    index._validity_opaque:bump('index changed')
  end
end

local function observe_version(ctx, index)
  local frontier = index._validity_opaque and index._validity_opaque:frontier_for() or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  return index.version or 0
end

function IndexKind.eval(index, payload, ctx)
  local op = payload.op
  if op == 'insert' then
    local c = Proposal.new(OpPack(true))
    insert_record(c, index, payload.key, payload.rank, payload.value, observe_version(ctx, index), payload.seq)
    return Result.ready(c)
  elseif op == 'append' then
    local c = Proposal.new(OpPack(true))
    insert_record(c, index, payload.key, math.huge, payload.value, observe_version(ctx, index), payload.seq)
    return Result.ready(c)
  elseif op == 'insert_auto' then
    local c = Proposal.new(OpPack(true))
    insert_record(c, index, payload.key, payload.rank, payload.value, observe_version(ctx, index), payload.seq)
    return Result.ready(c)
  elseif op == 'remove' then
    local c = Proposal.new(OpPack(true))
    remove_record(c, index, payload.key, observe_version(ctx, index))
    return Result.ready(c)
  elseif op == 'snapshot' then
    local c = Proposal.new(OpPack(Resource.project(ctx, index, 'snapshot')))
    ensure_rec(c, index, observe_version(ctx, index))
    return Result.ready(c)
  elseif op == 'pop_first' or op == 'pop_last' then
    return Result.premise({ role = op })
  end
  error('unknown index command ' .. tostring(op), 2)
end

local function allocate(index, premises, ctx)
  local views = ctx.resource_record_views and ctx:resource_record_views(index, premises) or nil
  local entries = views and build_arena_from_views(index, views) or build_arena(index, ctx.resource_records and ctx:resource_records(index, premises) or nil)
  local used = {}
  local results = {}
  local ids = {}
  local chosen = {}

  for i = 1, #premises do
    local p = premises[i]
    local reverse = p.request and p.request.role == 'pop_last'
    local ordered = sorted_entries(entries, reverse)
    local e = nil
    for j = 1, #ordered do
      if not used[ordered[j].key] then e = ordered[j]; break end
    end
    if not e then return nil end
    used[e.key] = true
    entries[e.key] = nil -- later selections in the same solution cannot reuse it.
    ids[#ids + 1] = p.id
    results[p.id] = OpPack(copy_entry(e))
    chosen[#chosen + 1] = e
  end

  local c = Proposal.new(OpPack())
  local version = index.version or 0
  for i = 1, #chosen do selected_remove_record(c, index, chosen[i].key, version) end
  return { ids = ids, results = results, proposal = c }
end

function IndexKind.resolve_premises(index, premises, ctx)
  local pops = {}
  for i = 1, #(premises or {}) do
    local p = premises[i]
    local role = p.request and p.request.role
    if role == 'pop_first' or role == 'pop_last' then pops[#pops + 1] = p end
  end
  Premise.sort_by_id(pops)

  local out = {}
  if #pops > 0 and Premise.pairwise_compatible(pops, ctx) then
    local sol = allocate(index, pops, ctx)
    if sol then out[#out + 1] = sol end
  end

  -- Also offer single-premise solutions.  This keeps ordinary one-pop worlds
  -- available and gives the solver a conservative fallback when a group cannot
  -- be allocated together.
  for i = 1, #pops do
    local sol = allocate(index, { pops[i] }, ctx)
    if sol then out[#out + 1] = sol end
  end
  local frontier = index._validity_opaque and index._validity_opaque:frontier_for() or nil
  return Resolution.exhaustive_after(out, ctx, {
    { kind = 'index-solutions-exhausted', index = index, frontier = frontier, stamp = frontier and frontier.gen or nil },
  })
end

function Index.new(entries, name)
  next_id = next_id + 1
  local id = 'index-' .. tostring(next_id)
  local index = setmetatable({ name = name or id, _fibers_id = id, _fibers_kind = IndexKind, entries = {}, version = 0 }, Index)
  index._validity_opaque = Validity.epoch((index.name or id) .. ':index')
  for i = 1, #(entries or {}) do
    local e = entries[i]
    local key = e.key or i
    index.entries[key] = { key = key, rank = e.rank or i, value = e.value, seq = e.seq or i }
  end
  return index
end

function Index:insert_op(key, rank, value)
  if key == nil then error('index insert requires a key', 2) end
  if rank == nil then error('index insert requires a rank', 2) end
  return Op._resource(self, IndexKind, { op = 'insert', key = key, rank = rank, value = value })
end

function Index:insert_auto_op(rank, value)
  if rank == nil then error('index insert_auto requires a rank', 2) end
  next_append_id = next_append_id + 1
  local seq = next_append_id
  local key = (self._fibers_id or 'index') .. ':auto:' .. tostring(seq)
  return Op._resource(self, IndexKind, { op = 'insert_auto', key = key, rank = rank, seq = seq, value = value })
end

function Index:append_op(value)
  next_append_id = next_append_id + 1
  local seq = next_append_id
  local key = (self._fibers_id or 'index') .. ':append:' .. tostring(seq)
  return Op._resource(self, IndexKind, { op = 'append', key = key, seq = seq, value = value })
end

function Index:remove_op(key)
  if key == nil then error('index remove requires a key', 2) end
  return Op._resource(self, IndexKind, { op = 'remove', key = key })
end

function Index:pop_first_op()
  return Op._resource(self, IndexKind, { op = 'pop_first' })
end

function Index:pop_last_op()
  return Op._resource(self, IndexKind, { op = 'pop_last' })
end

function Index:snapshot_op()
  return Op._resource(self, IndexKind, { op = 'snapshot' })
end

Index.Kind = IndexKind
return Index
