-- Premise-aware bounded counter.
--
-- Counter is a merge-aware numeric stock. Positive deltas (give) are
-- ordinary resource records. Taking stock opens a premise so competing takes
-- can be allocated from the same committed/projected stock before Lua
-- continuations run.

local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Op = require('fibers.atoms.op')
local Wait = require('fibers.kernel.wait')
local Validity = require('fibers.kernel.validity')
local Premise = require('fibers.kernel.premise_helpers')

local OpPack = Op._pack

local Counter = {}
Counter.__index = Counter

local CounterKind = { name = 'counter' }
local next_id = 0

local function opt_number(opts, a, b)
  if type(opts) == 'number' then return opts end
  if type(opts) == 'table' then
    if opts[a] ~= nil then return opts[a] end
    if b and opts[b] ~= nil then return opts[b] end
  end
  return nil
end

local function ensure_rec(c, counter, version)
  local rec = Resource.ensure(c, counter, CounterKind)
  if rec.read == nil then rec.read = version or counter.version or 0 end
  rec.delta = rec.delta or 0
  return rec
end

local function delta_record(c, counter, n, version)
  local rec = ensure_rec(c, counter, version)
  rec.delta = (rec.delta or 0) + n
  return rec
end

function CounterKind.clone(rec)
  return { kind = CounterKind, read = rec.read, delta = rec.delta or 0 }
end

local function merge_read(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
end

function CounterKind.merge_seq(dst, src)
  merge_read(dst, src)
  dst.delta = (dst.delta or 0) + (src.delta or 0)
  return true
end

function CounterKind.merge_par(dst, src)
  merge_read(dst, src)
  dst.delta = (dst.delta or 0) + (src.delta or 0)
  return true
end

local function apply_delta_value(counter, delta)
  return (counter.value or 0) + (delta or 0)
end

function CounterKind.project(counter, rec, query)
  if query == 'value' then
    return apply_delta_value(counter, rec and rec.delta or 0), true
  elseif query == 'state' then
    return {
      value = apply_delta_value(counter, rec and rec.delta or 0),
      min = counter.min,
      max = counter.max,
      version = counter.version or 0,
      _fibers_counter_state = true,
    }, true
  end
  return nil, false
end

function CounterKind.prepare(counter, rec, _resolve)
  if rec.read ~= nil and (counter.version or 0) ~= rec.read then return nil, 'stale' end
  local delta = rec.delta or 0
  local final = (counter.value or 0) + delta
  if counter.min ~= nil and final < counter.min then return nil, 'counter-underflow' end
  if counter.max ~= nil and final > counter.max then return nil, 'counter-overflow' end
  if delta == 0 then return nil, nil, true end
  return { kind = CounterKind, resource = counter, delta = delta }
end

function CounterKind.apply(prepared, _log)
  local counter = prepared.resource
  local delta = prepared.delta or 0
  if delta ~= 0 then
    counter.value = (counter.value or 0) + delta
    counter.version = (counter.version or 0) + 1
    counter._validity_opaque:bump('counter changed')
  end
end

local function observe_version(ctx, counter)
  local frontier = counter._validity_opaque and counter._validity_opaque:frontier_for() or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  return counter.version or 0
end

function CounterKind.eval(counter, payload, ctx)
  local op = payload.op
  if op == 'add' then
    local n = payload.amount or 0
    local c = Proposal.new(OpPack(true))
    delta_record(c, counter, n, observe_version(ctx, counter))
    return Result.ready(c)
  elseif op == 'read' then
    local c = Proposal.new(OpPack(Resource.project(ctx, counter, 'value')))
    ensure_rec(c, counter, observe_version(ctx, counter))
    return Result.ready(c)
  elseif op == 'state' then
    local c = Proposal.new(OpPack(Resource.project(ctx, counter, 'state')))
    ensure_rec(c, counter, observe_version(ctx, counter))
    return Result.ready(c)
  elseif op == 'take' then
    local amount = payload.amount or 1
    if amount <= 0 then
      local c = Proposal.new(OpPack(true))
      return Result.ready(c)
    end
    local wait = Wait.resource('counter', counter._fibers_id, counter, { op = op, amount = amount })
    return Result.premise({ role = 'take', amount = amount }, wait)
  end
  error('unknown counter command ' .. tostring(op), 2)
end

local function visible_delta_for_view(view)
  local rec = Premise.record_from_view(view)
  if not rec then return 0 end
  local d = rec.delta or 0
  -- `all` lanes may not positively supply another lane.  Their negative
  -- deltas still constrain joint allocation.  Tensor-internal sibling positive
  -- deltas are visible as handoff supply.
  if view and view.relation == 'sibling' and view.allow_internal == false and d > 0 then return 0 end
  return d
end

local function projected_value_from_views(counter, views)
  local v = counter.value or 0
  for i = 1, #(views or {}) do v = v + visible_delta_for_view(views[i]) end
  return v
end

local function projected_value_from_records(counter, records)
  local v = counter.value or 0
  for i = 1, #(records or {}) do v = v + ((records[i] and records[i].delta) or 0) end
  return v
end

local function available(counter, premises, ctx)
  local views = ctx and ctx.resource_record_views and ctx:resource_record_views(counter, premises) or nil
  local projected = views and projected_value_from_views(counter, views) or projected_value_from_records(counter, ctx and ctx.resource_records and ctx:resource_records(counter, premises) or nil)
  local min = counter.min or 0
  return projected - min
end

local function allocate(counter, premises, ctx)
  local avail = available(counter, premises, ctx)
  local ids, results = {}, {}
  local total = 0
  for i = 1, #premises do
    local p = premises[i]
    local amount = (p.request and p.request.amount) or 1
    if amount < 0 then return nil end
    if total + amount > avail then return nil end
    total = total + amount
    ids[#ids + 1] = p.id
    results[p.id] = OpPack(true)
  end
  local c = Proposal.new(OpPack())
  delta_record(c, counter, -total, counter.version or 0)
  return { ids = ids, results = results, proposal = c }
end

function CounterKind.resolve_premises(counter, premises, ctx)
  local takes = {}
  for i = 1, #(premises or {}) do
    local p = premises[i]
    if p.request and p.request.role == 'take' then takes[#takes + 1] = p end
  end
  Premise.sort_by_id(takes)

  local out = {}
  if #takes > 0 and Premise.pairwise_compatible(takes, ctx) then
    local sol = allocate(counter, takes, ctx)
    if sol then out[#out + 1] = sol end
  end
  for i = 1, #takes do
    local sol = allocate(counter, { takes[i] }, ctx)
    if sol then out[#out + 1] = sol end
  end
  return out
end

function CounterKind.absence_premises(counter, premises, ctx)
  local avail = available(counter, premises, ctx)
  local ok = true
  for i = 1, #(premises or {}) do
    local amount = (premises[i].request and premises[i].request.amount) or 1
    if avail >= amount then ok = false; break end
  end
  if not ok then return false end
  local frontier = counter._validity_opaque and counter._validity_opaque:frontier_for() or nil
  if ctx and ctx.observe_frontier then ctx:observe_frontier(frontier) end
  for i = 1, #(premises or {}) do
    local p = premises[i]
    if ctx and ctx.add then
      ctx:add({ kind = 'counter-insufficient', counter = counter, amount = p.request and p.request.amount, frontier = frontier, stamp = frontier and frontier.gen or nil })
    end
  end
  return true
end

function CounterKind.absence(counter, payload, ctx)
  if payload and payload.op == 'take' then
    return CounterKind.absence_premises(counter, { { request = { role = 'take', amount = payload.amount or 1 } } }, ctx)
  end
  return false
end

function Counter.new(opts, name)
  local initial, min, max
  if type(opts) == 'table' then
    initial = opt_number(opts, 'initial', 'value')
    min = opts.min
    max = opts.max
    name = opts.name or name
  else
    initial = opts
  end
  if initial == nil then initial = 0 end
  if min == nil then min = 0 end
  next_id = next_id + 1
  local id = 'counter-' .. tostring(next_id)
  local counter = setmetatable({ name = name or id, _fibers_id = id, _fibers_kind = CounterKind, value = initial, min = min, max = max, version = 0 }, Counter)
  counter._validity_opaque = Validity.epoch((counter.name or id) .. ':counter')
  return counter
end

function Counter:adjust_op(n)
  if n == nil then error('counter adjust requires an amount', 2) end
  return Op._resource(self, CounterKind, { op = 'add', amount = n })
end

function Counter:add_op(n)
  if n == nil then error('counter add requires an amount', 2) end
  if n < 0 then error('counter add requires a non-negative amount; use adjust_op for signed expert adjustments or take_op for allocated demand', 2) end
  return self:adjust_op(n)
end

function Counter:give_op(n)
  n = n or 1
  if n < 0 then error('counter give requires a non-negative amount', 2) end
  return self:adjust_op(n)
end

function Counter:take_op(n)
  n = n or 1
  if n < 0 then error('counter take requires a non-negative amount', 2) end
  return Op._resource(self, CounterKind, { op = 'take', amount = n })
end

function Counter:read_op()
  return Op._resource(self, CounterKind, { op = 'read' })
end

function Counter:state_op()
  return Op._resource(self, CounterKind, { op = 'state' })
end

Counter.Kind = CounterKind
return Counter
