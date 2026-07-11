-- Transactional compatibility leases.
--
-- Lease is a proof-premise based compatibility atom.  Acquisitions demand
-- compatible availability and may be allocated together. Releases are ordinary
-- records: under tensor they may supply availability to sibling acquires; under
-- all they do not positively supply availability to sibling acquires.

local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Resolution = require('fibers.kernel.resources.resolution')
local Op = require('fibers.atoms.op')
local Validity = require('fibers.kernel.validity')
local Premise = require('fibers.kernel.premise_helpers')

local OpPack = Op._pack

local Lease = {}
Lease.__index = Lease

local LeaseKind = { name = 'lease' }
local next_id = 0

local function clone_subjects(subjects)
  local out = {}
  for s, holders in pairs(subjects or {}) do
    out[s] = {}
    for owner, mode in pairs(holders or {}) do out[s][owner] = mode end
  end
  return out
end
local function clone_nested_bool(m)
  local out = {}
  for s, owners in pairs(m or {}) do
    out[s] = {}
    for o, v in pairs(owners or {}) do if v then out[s][o] = true end end
  end
  return out
end
local function clone_nested_value(m)
  local out = {}
  for s, owners in pairs(m or {}) do
    out[s] = {}
    for o, v in pairs(owners or {}) do out[s][o] = v end
  end
  return out
end
local function map_empty(m)
  for _, sub in pairs(m or {}) do for _ in pairs(sub or {}) do return false end end
  return true
end

local function subject_version(leases, subject) return (leases.versions and leases.versions[subject]) or 0 end
local function observe_subject(ctx, leases, subject)
  local frontier = leases._validity and leases._validity:frontier_for('membership', subject) or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  return subject_version(leases, subject)
end

local function observe_structure(ctx, leases)
  local frontier = leases._validity and leases._validity:frontier_for('structure') or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  return leases.version or 0
end

local function ensure_rec(c, leases)
  local rec = Resource.ensure(c, leases, LeaseKind)
  rec.reads = rec.reads or {}
  rec.acquires = rec.acquires or {}
  rec.releases = rec.releases or {}
  return rec
end
local function read_subject(c, leases, subject, version)
  local rec = ensure_rec(c, leases)
  if rec.reads[subject] == nil then rec.reads[subject] = version or subject_version(leases, subject) end
  return rec
end
local function acquire_record(c, leases, subject, mode, owner, version)
  local rec = read_subject(c, leases, subject, version)
  rec.acquires[subject] = rec.acquires[subject] or {}
  rec.acquires[subject][owner] = mode
  return rec
end
local function release_record(c, leases, subject, owner, version)
  local rec = read_subject(c, leases, subject, version)
  rec.releases[subject] = rec.releases[subject] or {}
  rec.releases[subject][owner] = true
  return rec
end

function LeaseKind.clone(rec)
  local reads = {}
  for k, v in pairs(rec.reads or {}) do reads[k] = v end
  return { kind = LeaseKind, read_all = rec.read_all, reads = reads, acquires = clone_nested_value(rec.acquires), releases = clone_nested_bool(rec.releases) }
end
local function merge_reads(dst, src)
  if src.read_all ~= nil and dst.read_all == nil then dst.read_all = src.read_all end
  dst.reads = dst.reads or {}
  for s, v in pairs(src.reads or {}) do if dst.reads[s] == nil then dst.reads[s] = v end end
end
local function normalise(rec)
  if map_empty(rec.acquires) then rec.acquires = nil end
  if map_empty(rec.releases) then rec.releases = nil end
end
function LeaseKind.merge_seq(dst, src)
  merge_reads(dst, src)
  dst.acquires = dst.acquires or {}; dst.releases = dst.releases or {}
  for s, owners in pairs(src.releases or {}) do
    dst.releases[s] = dst.releases[s] or {}
    dst.acquires[s] = dst.acquires[s] or {}
    for o in pairs(owners) do dst.acquires[s][o] = nil; dst.releases[s][o] = true end
  end
  for s, owners in pairs(src.acquires or {}) do
    dst.acquires[s] = dst.acquires[s] or {}
    dst.releases[s] = dst.releases[s] or {}
    for o, mode in pairs(owners) do dst.releases[s][o] = nil; dst.acquires[s][o] = mode end
  end
  normalise(dst)
  return true
end
function LeaseKind.merge_par(dst, src)
  merge_reads(dst, src)
  dst.acquires = dst.acquires or {}; dst.releases = dst.releases or {}
  for s, owners in pairs(src.releases or {}) do
    dst.releases[s] = dst.releases[s] or {}
    dst.acquires[s] = dst.acquires[s] or {}
    for o in pairs(owners) do
      if dst.acquires[s][o] then return false, 'lease-conflict' end
      dst.releases[s][o] = true
    end
  end
  for s, owners in pairs(src.acquires or {}) do
    dst.acquires[s] = dst.acquires[s] or {}
    dst.releases[s] = dst.releases[s] or {}
    for o, mode in pairs(owners) do
      if dst.releases[s][o] then return false, 'lease-conflict' end
      if dst.acquires[s][o] and dst.acquires[s][o] ~= mode then return false, 'lease-conflict' end
      dst.acquires[s][o] = mode
    end
  end
  normalise(dst)
  return true
end

local function holders_for(leases, subject)
  local out = {}
  for owner, mode in pairs((leases.holders and leases.holders[subject]) or {}) do out[owner] = mode end
  return out
end
local function apply_record_to_holders(holders, rec, hide_releases)
  if not hide_releases then
    for _s, owners in pairs(rec.releases or {}) do for owner in pairs(owners) do holders[owner] = nil end end
  end
  for _s, owners in pairs(rec.acquires or {}) do for owner, mode in pairs(owners) do holders[owner] = mode end end
end
local function record_from_view(view) return Premise.record_from_view(view) end
local function projected_holders(leases, subject, views, hide_all_sibling_releases)
  local holders = holders_for(leases, subject)
  for i = 1, #(views or {}) do
    local view = views[i]
    local rec = record_from_view(view)
    if rec then
      local subrec = { acquires = rec.acquires and rec.acquires[subject] and { [subject] = rec.acquires[subject] } or nil,
                       releases = rec.releases and rec.releases[subject] and { [subject] = rec.releases[subject] } or nil }
      local hide = hide_all_sibling_releases and view and view.relation == 'sibling' and view.mode == 'independent'
      apply_record_to_holders(holders, subrec, hide)
    end
  end
  return holders
end
local function compatible_modes(leases, a, b)
  if a == b then return true end
  local row = leases.compat and leases.compat[a]
  return row and row[b] == true
end
local function can_add(leases, holders, owner, mode)
  for o, m in pairs(holders or {}) do
    if o ~= owner and not (compatible_modes(leases, mode, m) and compatible_modes(leases, m, mode)) then return false end
  end
  return true
end

function LeaseKind.project(leases, rec, query)
  if type(query) == 'table' and query.kind == 'holders' then
    local h = holders_for(leases, query.subject)
    if rec then apply_record_to_holders(h, { acquires = rec.acquires and rec.acquires[query.subject] and { [query.subject] = rec.acquires[query.subject] } or nil, releases = rec.releases and rec.releases[query.subject] and { [query.subject] = rec.releases[query.subject] } or nil }) end
    return h, true
  elseif query == 'snapshot' then
    return { holders = clone_subjects(leases.holders), version = leases.version or 0, _fibers_lease_snapshot = true }, true
  end
  return nil, false
end

function LeaseKind.prepare(leases, rec)
  if rec.read_all ~= nil and (leases.version or 0) ~= rec.read_all then return nil, 'stale' end
  for s, v in pairs(rec.reads or {}) do if subject_version(leases, s) ~= v then return nil, 'stale' end end
  local subjects = {}
  for s in pairs(rec.releases or {}) do subjects[s] = true end
  for s in pairs(rec.acquires or {}) do subjects[s] = true end
  for s in pairs(subjects) do
    local h = holders_for(leases, s)
    for owner in pairs((rec.releases or {})[s] or {}) do
      if h[owner] == nil then return nil, 'lease-not-held' end
      h[owner] = nil
    end
    for owner, mode in pairs((rec.acquires or {})[s] or {}) do
      if not can_add(leases, h, owner, mode) then return nil, 'lease-incompatible' end
      h[owner] = mode
    end
  end
  if not rec.acquires and not rec.releases then return nil, nil, true end
  return { kind = LeaseKind, resource = leases, acquires = clone_nested_value(rec.acquires), releases = clone_nested_bool(rec.releases) }
end
function LeaseKind.apply(prepared)
  local leases = prepared.resource
  local changed = {}
  for s, owners in pairs(prepared.releases or {}) do
    leases.holders[s] = leases.holders[s] or {}
    for o in pairs(owners) do if leases.holders[s][o] ~= nil then leases.holders[s][o] = nil; changed[s] = true end end
  end
  for s, owners in pairs(prepared.acquires or {}) do
    leases.holders[s] = leases.holders[s] or {}
    for o, mode in pairs(owners) do if leases.holders[s][o] ~= mode then leases.holders[s][o] = mode; changed[s] = true end end
  end
  for s in pairs(changed) do
    leases.versions[s] = (leases.versions[s] or 0) + 1
    leases.version = (leases.version or 0) + 1
    leases._validity:set(s, leases.holders[s], 'lease changed')
  end
end

function LeaseKind.eval(leases, payload, ctx)
  local op = payload.op
  if op == 'release' then
    local c = Proposal.new(OpPack(true))
    release_record(c, leases, payload.subject, payload.owner, observe_subject(ctx, leases, payload.subject))
    return Result.ready(c)
  elseif op == 'snapshot' then
    local c = Proposal.new(OpPack(Resource.project(ctx, leases, 'snapshot')))
    local rec = ensure_rec(c, leases)
    rec.read_all = observe_structure(ctx, leases)
    return Result.ready(c)
  elseif op == 'acquire' then
    return Result.premise({ role = 'acquire', subject = payload.subject, mode = payload.mode, owner = payload.owner })
  end
  error('unknown lease command ' .. tostring(op), 2)
end

local function allocate(leases, premises, ctx)
  local ids, results = {}, {}
  local c = Proposal.new(OpPack())
  local by_subject = {}
  for i = 1, #premises do
    local p = premises[i]
    by_subject[p.request.subject] = by_subject[p.request.subject] or {}
    by_subject[p.request.subject][#by_subject[p.request.subject] + 1] = p
  end
  for subject, ps in pairs(by_subject) do
    local views = ctx.resource_record_views and ctx:resource_record_views(leases, ps) or nil
    local holders = projected_holders(leases, subject, views, true)
    for i = 1, #ps do
      local r = ps[i].request
      if not can_add(leases, holders, r.owner, r.mode) then return nil end
      holders[r.owner] = r.mode
      acquire_record(c, leases, subject, r.mode, r.owner, subject_version(leases, subject))
      ids[#ids + 1] = ps[i].id; results[ps[i].id] = OpPack(true)
    end
  end
  return { ids = ids, results = results, proposal = c }
end
function LeaseKind.resolve_premises(leases, premises, ctx)
  local ps = {}
  for i = 1, #(premises or {}) do if premises[i].request and premises[i].request.role == 'acquire' then ps[#ps + 1] = premises[i] end end
  Premise.sort_by_id(ps)
  local out = {}
  if #ps > 0 and Premise.pairwise_compatible(ps, ctx) then local sol = allocate(leases, ps, ctx); if sol then out[#out + 1] = sol end end
  for i = 1, #ps do local sol = allocate(leases, { ps[i] }, ctx); if sol then out[#out + 1] = sol end end
  local observations = {}
  for i = 1, #ps do
    local p = ps[i]
    local frontier = leases._validity and leases._validity:frontier_for('membership', p.request.subject) or nil
    observations[#observations + 1] = { kind = 'lease-solutions-exhausted', leases = leases, subject = p.request.subject, frontier = frontier, stamp = frontier and frontier.gen or nil }
  end
  return Resolution.exhaustive_after(out, ctx, observations)
end
function Lease.new(compat, name)
  next_id = next_id + 1
  local id = 'lease-' .. tostring(next_id)
  local leases = setmetatable({ name = name or id, _fibers_id = id, _fibers_kind = LeaseKind, holders = {}, versions = {}, version = 0, compat = compat or { lease = {} } }, Lease)
  leases._validity = Validity.map((leases.name or id) .. ':lease')
  return leases
end
function Lease:acquire_op(subject, mode, owner)
  if subject == nil then error('lease acquire requires subject', 2) end
  if mode == nil then error('lease acquire requires mode', 2) end
  if owner == nil then error('lease acquire requires owner', 2) end
  return Op._resource(self, LeaseKind, { op = 'acquire', subject = subject, mode = mode, owner = owner })
end
function Lease:release_op(subject, owner)
  if subject == nil then error('lease release requires subject', 2) end
  if owner == nil then error('lease release requires owner', 2) end
  return Op._resource(self, LeaseKind, { op = 'release', subject = subject, owner = owner })
end
function Lease:snapshot_op() return Op._resource(self, LeaseKind, { op = 'snapshot' }) end

Lease.Kind = LeaseKind
return Lease
