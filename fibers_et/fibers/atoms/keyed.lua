-- Transactional keyed map/set atom.
--
-- Keyed is a proof-premise based per-key map.  Presence-demanding
-- operations open premises so a tensor sibling may supply a value, while all
-- lanes remain independently satisfiable: sibling puts constrain absence but
-- do not positively supply gets/removes under all.

local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Resolution = require('fibers.kernel.resources.resolution')
local Op = require('fibers.atoms.op')
local Validity = require('fibers.kernel.validity')
local Premise = require('fibers.kernel.premise_helpers')
local Presence = require('fibers.kernel.resources.presence_journal')

local OpPack = Op._pack

local Keyed = {}
Keyed.__index = Keyed

local KeyedKind = { name = 'keyed' }
local next_id = 0
local NIL = {}

local function enc(v) return v == nil and NIL or v end
local function dec(v) if v == NIL then return nil end; return v end

local function clone_entries(m)
  local out = {}
  for k, v in pairs(m or {}) do out[k] = v end
  return out
end
local function key_version(map, key) return (map.versions and map.versions[key]) or 0 end
local function observe_key(ctx, map, key)
  local frontier = map._validity and map._validity:frontier_for('membership', key) or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  return key_version(map, key)
end
local function observe_structure(ctx, map)
  local frontier = map._validity and map._validity:frontier_for('structure') or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  return map.version or 0
end

local function ensure_rec(c, map)
  local rec = Resource.ensure(c, map, KeyedKind)
  rec.reads = rec.reads or {}
  rec.puts = rec.puts or {}
  rec.replacements = rec.replacements or {}
  rec.removes = rec.removes or {}
  rec.selected_removes = rec.selected_removes or {}
  return rec
end

local function overlay_has_removal(ctx, map, key)
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[map]
  return rec and ((rec.removes and rec.removes[key]) or (rec.selected_removes and rec.selected_removes[key])) or false
end

local function read_key_record(c, map, key, version)
  local rec = ensure_rec(c, map)
  if rec.reads[key] == nil then rec.reads[key] = version or key_version(map, key) end
  return rec
end

local function put_record(c, map, key, value, version, replacement)
  local rec = read_key_record(c, map, key, version)
  rec.removes[key] = nil
  rec.selected_removes[key] = nil
  rec.puts[key] = enc(value)
  if replacement then rec.replacements[key] = true end
  return rec
end

local function remove_record(c, map, key, version)
  local rec = read_key_record(c, map, key, version)
  rec.puts[key] = nil
  rec.selected_removes[key] = nil
  rec.removes[key] = true
  return rec
end

local function selected_remove_record(c, map, key, version)
  local rec = read_key_record(c, map, key, version)
  if rec.puts[key] ~= nil then rec.puts[key] = nil else rec.selected_removes[key] = true end
  return rec
end

function KeyedKind.clone(rec)
  return {
    kind = KeyedKind,
    read_all = rec.read_all,
    reads = clone_entries(rec.reads),
    puts = clone_entries(rec.puts),
    replacements = Premise.clone_bool_map(rec.replacements),
    removes = Premise.clone_bool_map(rec.removes),
    selected_removes = Premise.clone_bool_map(rec.selected_removes),
  }
end

local function merge_reads(dst, src)
  if src.read_all ~= nil and dst.read_all == nil then dst.read_all = src.read_all end
  dst.reads = dst.reads or {}
  for k, v in pairs(src.reads or {}) do if dst.reads[k] == nil then dst.reads[k] = v end end
end

local function normalise(rec)
  Presence.normalise(rec, 'puts', true)
end

function KeyedKind.merge_seq(dst, src)
  merge_reads(dst, src)
  return Presence.merge_seq(dst, src, { field = 'puts', conflict = 'keyed-conflict', replacements = true })
end

function KeyedKind.merge_par(dst, src)
  merge_reads(dst, src)
  return Presence.merge_par(dst, src, { field = 'puts', conflict = 'keyed-conflict', replacements = true })
end

local function base_entries(map)
  local out = {}
  for k, v in pairs(map.entries or {}) do out[k] = v end
  return out
end
local function apply_record(entries, rec)
  Presence.apply_to_entries(entries, rec, 'puts')
end
local function record_from_view(view) return Premise.record_from_view(view) end
local function constraint_record(rec)
  return { kind = KeyedKind, reads = clone_entries(rec and rec.reads), removes = Premise.clone_bool_map(rec and rec.removes), selected_removes = Premise.clone_bool_map(rec and rec.selected_removes), puts = {} }
end
local function view_record(view, mode)
  local rec = record_from_view(view)
  if not rec then return nil end
  if Premise.sibling_supply_hidden(view) then
    if mode == 'demand_presence' then return constraint_record(rec) end
    -- For absence-demanding operations, sibling puts are constraints too.
  end
  return rec
end
local function projected_from_views(map, views, mode)
  local entries = base_entries(map)
  for i = 1, #(views or {}) do
    local rec = view_record(views[i], mode)
    if rec then apply_record(entries, rec) end
  end
  return entries
end

function KeyedKind.project(map, rec, query)
  local entries = base_entries(map)
  if rec then apply_record(entries, rec) end
  if type(query) == 'table' and query.kind == 'get' then return dec(entries[query.key]), entries[query.key] ~= nil end
  if type(query) == 'table' and query.kind == 'contains' then return entries[query.key] ~= nil, true end
  if query == 'snapshot' then
    local out = {}
    for k, v in pairs(entries) do out[k] = dec(v) end
    return { entries = out, version = map.version or 0, _fibers_keyed_snapshot = true }, true
  end
  return nil, false
end

function KeyedKind.prepare(map, rec, _resolve)
  if rec.read_all ~= nil and (map.version or 0) ~= rec.read_all then return nil, 'stale' end
  for k, v in pairs(rec.reads or {}) do if key_version(map, k) ~= v then return nil, 'stale' end end
  local projected = base_entries(map)
  for k in pairs(rec.removes or {}) do if projected[k] == nil then return nil, 'keyed-missing' end; projected[k] = nil end
  for k in pairs(rec.selected_removes or {}) do if projected[k] == nil then return nil, 'keyed-missing' end; projected[k] = nil end
  for k, v in pairs(rec.puts or {}) do projected[k] = v end
  if not rec.puts and not rec.removes and not rec.selected_removes then return nil, nil, true end
  return { kind = KeyedKind, resource = map, puts = clone_entries(rec.puts), removes = Premise.clone_bool_map(rec.removes), selected_removes = Premise.clone_bool_map(rec.selected_removes) }
end

function KeyedKind.apply(prepared)
  local map = prepared.resource
  local changed = false
  for k in pairs(prepared.removes or {}) do if map.entries[k] ~= nil then map.entries[k] = nil; map.versions[k] = (map.versions[k] or 0) + 1; changed = true; map._validity:remove(k, 'keyed remove') end end
  for k in pairs(prepared.selected_removes or {}) do if map.entries[k] ~= nil then map.entries[k] = nil; map.versions[k] = (map.versions[k] or 0) + 1; changed = true; map._validity:remove(k, 'keyed selected remove') end end
  for k, v in pairs(prepared.puts or {}) do map.entries[k] = v; map.versions[k] = (map.versions[k] or 0) + 1; changed = true; map._validity:set(k, dec(v), 'keyed put') end
  if changed then map.version = (map.version or 0) + 1 end
end

function KeyedKind.eval(map, payload, ctx)
  local op, key = payload.op, payload.key
  if op == 'peek' then
    local version = observe_key(ctx, map, key)
    local c = Proposal.new(OpPack(Resource.project(ctx, map, { kind = 'get', key = key })))
    read_key_record(c, map, key, version)
    return Result.ready(c)
  elseif op == 'contains' then
    local version = observe_key(ctx, map, key)
    local c = Proposal.new(OpPack(Resource.project(ctx, map, { kind = 'contains', key = key })))
    read_key_record(c, map, key, version)
    return Result.ready(c)
  elseif op == 'put' then
    local c = Proposal.new(OpPack(true))
    put_record(c, map, key, payload.value, observe_key(ctx, map, key), overlay_has_removal(ctx, map, key))
    return Result.ready(c)
  elseif op == 'remove' then
    local c = Proposal.new(OpPack(true))
    remove_record(c, map, key, observe_key(ctx, map, key))
    return Result.ready(c)
  elseif op == 'snapshot' then
    local c = Proposal.new(OpPack(Resource.project(ctx, map, 'snapshot')))
    local rec = ensure_rec(c, map); rec.read_all = observe_structure(ctx, map)
    return Result.ready(c)
  elseif op == 'get' or op == 'remove_present' or op == 'put_absent' then
    return Result.premise({ role = op, key = key, value = payload.value })
  end
  error('unknown keyed command ' .. tostring(op), 2)
end

local function allocate(map, premises, ctx)
  local mode = 'demand_presence'
  for i = 1, #premises do if premises[i].request.role == 'put_absent' then mode = 'demand_absence' end end
  local views = ctx.resource_record_views and ctx:resource_record_views(map, premises) or nil
  local entries = projected_from_views(map, views, mode)
  local c = Proposal.new(OpPack())
  local ids, results = {}, {}
  for i = 1, #premises do
    local p = premises[i]
    local r, k = p.request.role, p.request.key
    local v = entries[k]
    if r == 'get' then
      if v == nil then return nil end
      ids[#ids + 1] = p.id; results[p.id] = OpPack(dec(v))
    elseif r == 'remove_present' then
      if v == nil then return nil end
      entries[k] = nil
      selected_remove_record(c, map, k, key_version(map, k))
      ids[#ids + 1] = p.id; results[p.id] = OpPack(dec(v))
    elseif r == 'put_absent' then
      if v ~= nil then return nil end
      entries[k] = enc(p.request.value)
      put_record(c, map, k, p.request.value, key_version(map, k))
      ids[#ids + 1] = p.id; results[p.id] = OpPack(true)
    end
  end
  return { ids = ids, results = results, proposal = c }
end
function KeyedKind.resolve_premises(map, premises, ctx)
  local ps = {}
  for i = 1, #(premises or {}) do
    local role = premises[i].request and premises[i].request.role
    if role == 'get' or role == 'remove_present' or role == 'put_absent' then ps[#ps + 1] = premises[i] end
  end
  Premise.sort_by_id(ps)
  local out = {}
  if #ps > 0 and Premise.pairwise_compatible(ps, ctx) then local sol = allocate(map, ps, ctx); if sol then out[#out + 1] = sol end end
  for i = 1, #ps do local sol = allocate(map, { ps[i] }, ctx); if sol then out[#out + 1] = sol end end
  local observations = {}
  for i = 1, #ps do
    local p = ps[i]
    local frontier = map._validity and map._validity:frontier_for('membership', p.request.key) or nil
    observations[#observations + 1] = { kind = 'keyed-solutions-exhausted', map = map, role = p.request.role, key = p.request.key, frontier = frontier, stamp = frontier and frontier.gen or nil }
  end
  return Resolution.exhaustive_after(out, ctx, observations)
end

function Keyed.new(entries, name)
  next_id = next_id + 1
  local id = 'keyed-' .. tostring(next_id)
  local m = setmetatable({ name = name or id, _fibers_id = id, _fibers_kind = KeyedKind, entries = {}, versions = {}, version = 0 }, Keyed)
  m._validity = Validity.map((m.name or id) .. ':keyed')
  for k, v in pairs(entries or {}) do m.entries[k] = enc(v); m.versions[k] = 0; m._validity:set(k, v, 'keyed init') end
  return m
end
function Keyed:get_op(key) if key == nil then error('keyed get requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'get', key = key }) end
function Keyed:peek_op(key) if key == nil then error('keyed peek requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'peek', key = key }) end
function Keyed:contains_op(key) if key == nil then error('keyed contains requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'contains', key = key }) end
function Keyed:put_op(key, value) if key == nil then error('keyed put requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'put', key = key, value = value }) end
function Keyed:put_absent_op(key, value) if key == nil then error('keyed put_absent requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'put_absent', key = key, value = value }) end
function Keyed:remove_op(key) if key == nil then error('keyed remove requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'remove', key = key }) end
function Keyed:remove_present_op(key) if key == nil then error('keyed remove_present requires key', 2) end; return Op._resource(self, KeyedKind, { op = 'remove_present', key = key }) end
function Keyed:snapshot_op() return Op._resource(self, KeyedKind, { op = 'snapshot' }) end

Keyed.Kind = KeyedKind
return Keyed
