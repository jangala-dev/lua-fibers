-- Transactional Scalar.
--
-- Scalar is the transactional single-value state atom. Reads
-- and writes are journalled, and `expect_op(value)` is a premise demand over
-- the projected scalar value.  Sibling writes that make an expectation false
-- are constraints under both all and tensor; sibling writes that make an
-- expectation true are positive supply and are visible only under tensor.

local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Op = require('fibers.atoms.op')
local Wait = require('fibers.kernel.wait')
local Validity = require('fibers.kernel.validity')
local Premise = require('fibers.kernel.premise_helpers')
local OpPack = Op._pack

local Scalar = {}
Scalar.__index = Scalar

local ScalarKind = { name = 'scalar' }
local next_id = 0

local function equal(a, b) return a == b end

local function copy_updates(updates)
  if not updates then return nil end
  local out = {}
  for i = 1, #updates do out[i] = { id = updates[i].id, value = updates[i].value } end
  return out
end

local function append_updates(dst, src)
  if not src then return end
  dst.updates = dst.updates or {}
  for i = 1, #src do dst.updates[#dst.updates + 1] = { id = src[i].id, value = src[i].value } end
  table.sort(dst.updates, function(a, b) return (a.id or 0) < (b.id or 0) end)
end

local function projected_value(scalar, rec)
  local value = scalar.value
  if rec and rec.has_write then value = rec.write end
  if rec and rec.updates then
    table.sort(rec.updates, function(a, b) return (a.id or 0) < (b.id or 0) end)
    for i = 1, #rec.updates do value = rec.updates[i].value end
  end
  return value
end

local function merge_read(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
end

local function read_record(c, scalar, version)
  local rec = Resource.ensure(c, scalar, ScalarKind)
  rec.read = rec.read or (version or scalar.version or 0)
  return rec
end

local function expect_record(c, scalar, expected, version)
  local rec = read_record(c, scalar, version)
  if rec.has_expect and not equal(rec.expect, expected) then return nil, 'scalar-conflict' end
  rec.has_expect = true
  rec.expect = expected
  return rec
end

local function write_record(c, scalar, value, version)
  local rec = read_record(c, scalar, version)
  rec.has_write = true
  rec.write = value
  rec.updates = nil
  return rec
end

local function update_record(c, scalar, value, id, version)
  local rec = read_record(c, scalar, version)
  rec.updates = rec.updates or {}
  rec.updates[#rec.updates + 1] = { id = id or 0, value = value }
  return rec
end

local function projected_version(scalar, rec)
  if rec and (rec.has_write or (rec.updates and #rec.updates > 0)) then return (scalar.version or 0) + 1 end
  return scalar.version or 0
end

function ScalarKind.clone(rec)
  return { kind = ScalarKind, read = rec.read, has_expect = rec.has_expect, expect = rec.expect, has_write = rec.has_write, write = rec.write, updates = copy_updates(rec.updates) }
end

function ScalarKind.merge_seq(dst, src)
  merge_read(dst, src)
  if src.has_expect then
    if dst.has_expect and not equal(dst.expect, src.expect) then return false, 'scalar-conflict' end
    dst.has_expect = true
    dst.expect = src.expect
  end
  if src.has_write then
    -- A later write is sequenced after any prior expectation and is allowed.
    dst.has_expect = nil
    dst.expect = nil
    dst.has_write = true
    dst.write = src.write
    dst.updates = nil
  end
  if src.updates and #src.updates > 0 then
    dst.has_expect = nil
    dst.expect = nil
  end
  append_updates(dst, src.updates)
  return true
end

function ScalarKind.merge_par(dst, src)
  merge_read(dst, src)
  if src.has_expect then
    if dst.has_expect and not equal(dst.expect, src.expect) then return false, 'scalar-conflict' end
    if (dst.has_write or (dst.updates and #dst.updates > 0)) and not equal(projected_value({ value = nil }, dst), src.expect) then return false, 'scalar-conflict' end
    dst.has_expect = true
    dst.expect = src.expect
  end
  if src.has_write then
    if dst.has_expect and not equal(dst.expect, src.write) then return false, 'scalar-conflict' end
    if dst.has_write then
      if not equal(dst.write, src.write) then return false, 'scalar-conflict' end
    else
      dst.has_write = true; dst.write = src.write
    end
  end
  if src.updates and #src.updates > 0 and dst.has_expect then
    local pseudo = { has_write = dst.has_write, write = dst.write, updates = copy_updates(dst.updates) }
    append_updates(pseudo, src.updates)
    if not equal(projected_value({ value = nil }, pseudo), dst.expect) then return false, 'scalar-conflict' end
  end
  append_updates(dst, src.updates)
  return true
end

function ScalarKind.project(scalar, rec, query)
  if query == 'value' then
    return projected_value(scalar, rec), true
  elseif query == 'version' then
    return projected_version(scalar, rec), true
  elseif query == 'snapshot' then
    local value = projected_value(scalar, rec)
    return { scalar = scalar, value = value, version = projected_version(scalar, rec), _fibers_scalar_snapshot = true }, true
  end
  return nil, false
end

function ScalarKind.prepare(scalar, rec, resolve)
  if rec.read ~= nil and (scalar.version or 0) ~= rec.read then return nil, 'stale' end
  if rec.has_write or (rec.updates and #rec.updates > 0) then
    return { kind = ScalarKind, resource = scalar, write = resolve(projected_value(scalar, rec)) }
  end
  return nil, nil, true
end

function ScalarKind.apply(prepared)
  local scalar = prepared.resource
  scalar._validity_value:set(prepared.write, 'scalar write')
  scalar.version = (scalar.version or 0) + 1
end

local function observe_version(ctx, obj)
  if ctx then
    local f = ctx.observe_version
    if f then return f(ctx, obj) end
  end
  return obj.version or 0
end

local function apply_record(value, rec)
  if rec and rec.has_write then return rec.write end
  return value
end

local function record_from_view(view) return Premise.record_from_view(view) end

local function projected_value_from_views(scalar, views)
  local value = scalar.value
  for i = 1, #(views or {}) do
    local rec = record_from_view(views[i])
    if rec then
      local pseudo = { kind = ScalarKind, read = rec.read, has_write = rec.has_write, write = rec.write, updates = copy_updates(rec.updates) }
      value = projected_value({ value = value, version = scalar.version }, pseudo)
    end
  end
  return value
end

local function pack_tail(packed)
  local n = packed and (packed.n or #packed) or 0
  if n <= 1 then return OpPack(packed and packed[1] or nil) end
  local out = { _fibers_pack = true, n = n - 1 }
  for i = 2, n do out[i - 1] = packed[i] end
  return out
end

local function update_context(ctx)
  return { now = function() return ctx and ctx.now and ctx:now() or 0 end }
end

local function run_update(fn, value, ctx)
  if type(fn) ~= 'function' then return nil, nil, 'scalar-update-not-function' end
  local packed = OpPack(fn(value, update_context(ctx)))
  if (packed.n or #packed) == 0 then return nil, nil, 'scalar-update-returned-no-value' end
  return packed[1], pack_tail(packed), nil
end

local function run_select(fn, value, ctx)
  if type(fn) ~= 'function' then return nil, nil, 'scalar-select-not-function' end
  local packed = OpPack(fn(value, update_context(ctx)))
  if (packed.n or #packed) == 0 or packed[1] == nil then return nil, nil, nil end
  return packed[1], pack_tail(packed), nil
end

local function select_succeeds(fn, value, ctx)
  local new_value = run_select(fn, value, ctx)
  return new_value ~= nil
end

local function scalar_record_changed(rec)
  return rec and (rec.has_write or (rec.updates and #rec.updates > 0))
end

local function scalar_apply_record(value, rec)
  return projected_value({ value = value, version = 0 }, rec)
end

local function projected_for_select(scalar, fn, views, ctx)
  return Premise.project_selective(scalar.value, views, {
    changed = scalar_record_changed,
    apply = scalar_apply_record,
    succeeds = function(value) return select_succeeds(fn, value, ctx) end,
  })
end

local function projected_for_expect(scalar, expected, views)
  return Premise.project_selective(scalar.value, views, {
    changed = scalar_record_changed,
    apply = scalar_apply_record,
    succeeds = function(value) return equal(value, expected) end,
  })
end

function ScalarKind.eval(scalar, payload, ctx)
  local op = payload.op
  if op == 'read' then
    local version = observe_version(ctx, scalar)
    local c = Proposal.new(OpPack(Resource.project(ctx, scalar, 'value')))
    read_record(c, scalar, version)
    return Result.ready(c)
  elseif op == 'snapshot' then
    local version = observe_version(ctx, scalar)
    local c = Proposal.new(OpPack(Resource.project(ctx, scalar, 'snapshot')))
    read_record(c, scalar, version)
    return Result.ready(c)
  elseif op == 'write' then
    local version = observe_version(ctx, scalar)
    local c = Proposal.new(OpPack(true))
    write_record(c, scalar, payload.value, version)
    return Result.ready(c)
  elseif op == 'expect' then
    local wait = Wait.resource('scalar', scalar._fibers_id, scalar, { op = 'expect', value = payload.value })
    return Result.premise({ role = 'expect', value = payload.value }, wait)
  elseif op == 'update' then
    return Result.premise({ role = 'update', fn = payload.fn, transition = payload.transition, payload = payload.payload })
  elseif op == 'select' then
    local wait = Wait.resource('scalar', scalar._fibers_id, scalar, { op = 'select' })
    return Result.premise({ role = 'select', fn = payload.fn, transition = payload.transition, payload = payload.payload }, wait)
  elseif op == 'changed' then
    local observed = observe_version(ctx, scalar)
    local version = Resource.project(ctx, scalar, 'version')
    if version ~= payload.version then
      local c = Proposal.new(OpPack(Resource.project(ctx, scalar, 'value'), version))
      read_record(c, scalar, observed)
      return Result.ready(c)
    end
    return Result.wait(Wait.resource('scalar', scalar._fibers_id, scalar, { op = 'changed', version = payload.version }))
  end
  error('unknown scalar command ' .. tostring(op), 2)
end


local function allocate(scalar, premises, ctx)
  local ids, results = {}, {}
  local c = Proposal.new(OpPack())
  local views = ctx.resource_record_views and ctx:resource_record_views(scalar, premises) or nil
  for i = 1, #premises do
    local p = premises[i]
    local expected = p.request.value
    if not equal(projected_for_expect(scalar, expected, views), expected) then return nil end
    read_record(c, scalar, scalar.version or 0)
    ids[#ids + 1] = p.id
    results[p.id] = OpPack(true)
  end
  return { ids = ids, results = results, proposal = c }
end

local function max_update_id(views)
  local m = nil
  for i = 1, #(views or {}) do
    local rec = record_from_view(views[i])
    for _, u in ipairs((rec and rec.updates) or {}) do
      if u.id and (not m or u.id > m) then m = u.id end
    end
  end
  return m
end

local function transition_update_id(premise)
  local t = premise.request and premise.request.transition
  if t and t.order ~= nil then return t.order + ((premise.id or 0) / 1000000) end
  return premise.id or 0
end

local function update_solution(scalar, premise, ctx)
  local views = ctx.resource_record_views and ctx:resource_record_views(scalar, { premise }) or nil
  local current = projected_value_from_views(scalar, views)
  local new_value, results, err = run_update(premise.request.fn, current, ctx)
  if err then return nil, err end
  local c = Proposal.new(OpPack())
  local id = transition_update_id(premise)
  local max_id = max_update_id(views)
  if max_id and max_id >= id then id = max_id + 0.000001 end
  update_record(c, scalar, new_value, id, scalar.version or 0)
  return { ids = { premise.id }, results = { [premise.id] = results }, proposal = c }
end

local function select_solution(scalar, premise, ctx)
  local views = ctx.resource_record_views and ctx:resource_record_views(scalar, { premise }) or nil
  local current = projected_for_select(scalar, premise.request.fn, views, ctx)
  local new_value, results, err = run_select(premise.request.fn, current, ctx)
  if err or new_value == nil then return nil, err end
  local c = Proposal.new(OpPack())
  local id = transition_update_id(premise)
  local max_id = max_update_id(views)
  if max_id and max_id >= id then id = max_id + 0.000001 end
  update_record(c, scalar, new_value, id, scalar.version or 0)
  return { ids = { premise.id }, results = { [premise.id] = results }, proposal = c }
end

function ScalarKind.resolve_premises(scalar, premises, ctx)
  local expects, updates, selects = {}, {}, {}
  for i = 1, #(premises or {}) do
    local p = premises[i]
    if p.request and p.request.role == 'expect' then expects[#expects + 1] = p
    elseif p.request and p.request.role == 'update' then updates[#updates + 1] = p
    elseif p.request and p.request.role == 'select' then selects[#selects + 1] = p end
  end
  Premise.sort_by_id(expects)
  table.sort(updates, function(a, b) return transition_update_id(a) < transition_update_id(b) end)
  table.sort(selects, function(a, b) return transition_update_id(a) < transition_update_id(b) end)
  local out = {}
  if #expects > 0 and Premise.pairwise_compatible(expects, ctx) then local sol = allocate(scalar, expects, ctx); if sol then out[#out + 1] = sol end end
  for i = 1, #expects do local sol = allocate(scalar, { expects[i] }, ctx); if sol then out[#out + 1] = sol end end
  -- Update and select premises are deliberately resolved one at a time in
  -- transition order.  This makes Scalar a small serial state-machine atom:
  -- later transitions see earlier transition contributions through ordered
  -- proof frames, instead of racing to produce independent worlds.
  local transitions = {}
  for i = 1, #updates do transitions[#transitions + 1] = { kind = 'update', premise = updates[i] } end
  for i = 1, #selects do transitions[#transitions + 1] = { kind = 'select', premise = selects[i] } end
  table.sort(transitions, function(a, b) return transition_update_id(a.premise) < transition_update_id(b.premise) end)
  if #transitions > 0 then
    local t = transitions[1]
    local sol = t.kind == 'update' and update_solution(scalar, t.premise, ctx) or select_solution(scalar, t.premise, ctx)
    if sol then out[#out + 1] = sol end
  end
  return out
end

function ScalarKind.absence_premises(scalar, premises, ctx)
  local ok = true
  for i = 1, #(premises or {}) do
    local p = premises[i]
    local views = ctx and ctx.resource_record_views and ctx:resource_record_views(scalar, { p }) or nil
    if p.request.role == 'expect' then
      if equal(projected_for_expect(scalar, p.request.value, views), p.request.value) then ok = false end
    elseif p.request.role == 'select' then
      local current = projected_for_select(scalar, p.request.fn, views, ctx)
      if select_succeeds(p.request.fn, current, ctx) then ok = false end
    else
      ok = false
    end
  end
  if not ok then return false end
  for i = 1, #(premises or {}) do
    local frontier = scalar._validity_value and scalar._validity_value:frontier_for() or nil
    if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
    if ctx and ctx.add then ctx:add({ kind = 'scalar-premise-absent', scalar = scalar, role = premises[i].request.role, value = premises[i].request.value, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
  end
  return true
end

function ScalarKind.absence(scalar, payload, ctx)
  if payload and payload.op == 'expect' then
    return ScalarKind.absence_premises(scalar, { { request = { role = 'expect', value = payload.value } } }, ctx)
  elseif payload and payload.op == 'select' then
    return ScalarKind.absence_premises(scalar, { { request = { role = 'select', fn = payload.fn } } }, ctx)
  elseif payload and payload.op == 'changed' then
    local version = observe_version(ctx, scalar)
    if version == payload.version then
      local frontier = scalar._validity_value and scalar._validity_value:frontier_for() or nil
      if ctx and ctx.add then ctx:add({ kind = 'scalar-unchanged', scalar = scalar, version = version, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
      return true
    end
  end
  return false
end

function ScalarKind.summary(payload, out)
  out.resources = true
  out.closed = false
  local op = payload and payload.op
  if op == 'read' or op == 'snapshot' or op == 'changed' or op == 'expect' or op == 'update' or op == 'select' then out.reads = true end
  if op == 'write' or op == 'update' or op == 'select' then out.writes = true end
  if op == 'changed' or op == 'expect' or op == 'update' or op == 'select' then out.dynamic = true end
end

local function transition_name(spec)
  return spec.name or spec.id or '<anonymous-scalar-transition>'
end

local function normalise_transition(spec)
  if type(spec) ~= 'table' or spec._fibers_scalar_transition ~= true then
    error('scalar transition expected', 3)
  end
  return spec
end

function Scalar.transition(spec)
  if type(spec) ~= 'table' then error('Scalar.transition expects a table', 2) end
  if type(spec.step) ~= 'function' then error('Scalar.transition requires step', 2) end
  if spec.validate ~= nil and type(spec.validate) ~= 'function' then error('Scalar.transition validate must be a function', 2) end
  local mode = spec.mode or 'update'
  if mode ~= 'update' and mode ~= 'select' then error('scalar transition mode must be update or select', 2) end
  return {
    _fibers_scalar_transition = true,
    name = spec.name,
    mode = mode,
    step = spec.step,
    validate = spec.validate,
    order = spec.order,
  }
end

function Scalar.kind(spec)
  if type(spec) ~= 'table' then error('Scalar.kind expects a table', 2) end
  local name = spec.name or '<anonymous-scalar-kind>'
  local k = { _fibers_scalar_kind = true, name = name, transitions = {} }
  for tname, tspec in pairs(spec.transitions or {}) do
    local full = {}
    for kk, vv in pairs(tspec) do full[kk] = vv end
    full.name = full.name or (name .. '.' .. tostring(tname))
    k.transitions[tname] = Scalar.transition(full)
  end
  function k:transition(tname)
    local t = self.transitions[tname]
    if not t then error('unknown scalar transition ' .. tostring(tname), 2) end
    return t
  end
  return k
end

local function transition_fn(transition, payload)
  return function(state, ctx)
    return transition.step(state, payload, ctx)
  end
end

function Scalar.new(value, name)
  next_id = next_id + 1
  local id = 'scalar-' .. tostring(next_id)
  local scalar = setmetatable({ value = value, version = 0, name = name or id, _fibers_id = id, _fibers_kind = ScalarKind }, Scalar)
  scalar._validity_value = Validity.scalar(value, (scalar.name or id) .. ':value', { on_set = function(v) scalar.value = v end })
  return scalar
end

function Scalar:read_op() return Op._resource(self, ScalarKind, { op = 'read' }) end
function Scalar:snapshot_op() return Op._resource(self, ScalarKind, { op = 'snapshot' }) end
function Scalar:write_op(value) return Op._resource(self, ScalarKind, { op = 'write', value = value }) end
function Scalar:expect_op(value) return Op._resource(self, ScalarKind, { op = 'expect', value = value }) end
function Scalar:unsafe_update_op(fn)
  if type(fn) ~= 'function' then error('scalar unsafe_update expects a function', 2) end
  return Op._resource(self, ScalarKind, { op = 'update', fn = fn })
end
function Scalar:unsafe_select_op(fn)
  if type(fn) ~= 'function' then error('scalar unsafe_select expects a function', 2) end
  return Op._resource(self, ScalarKind, { op = 'select', fn = fn })
end
function Scalar:transition_op(transition, payload)
  transition = normalise_transition(transition)
  payload = payload or {}
  if transition.validate then transition.validate(payload) end
  local fn = transition_fn(transition, payload)
  if transition.mode == 'select' then
    return Op._resource(self, ScalarKind, { op = 'select', fn = fn, transition = transition, payload = payload })
  end
  return Op._resource(self, ScalarKind, { op = 'update', fn = fn, transition = transition, payload = payload })
end
function Scalar:changed_op(version) return Op._resource(self, ScalarKind, { op = 'changed', version = version }) end

Scalar.Kind = ScalarKind
return Scalar
