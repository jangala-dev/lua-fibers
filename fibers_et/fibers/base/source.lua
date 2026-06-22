-- Public transactional Source, implemented on managed validity capabilities.
--
-- Sources expose host/time/external facts to the Op algebra.  State is kept in
-- managed facts from fibers.kernel.validity; search observes and producer/commit
-- mutation bumps validity stamps through those fact operations.

local DefaultOp = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Wait = require('fibers.kernel.wait')
local Validity = require('fibers.kernel.validity')
local OpPack = DefaultOp._pack

local Source = {}
Source.__index = Source

local SourceKind = { name = 'source' }
local next_id = 0

local function normalise_readiness_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then error('readiness mode must be read or write', 3) end
  return mode
end

local function new_source(kind, fields)
  next_id = next_id + 1
  fields = fields or {}
  fields.kind = kind
  fields.name = fields.name or (kind .. '-' .. tostring(next_id))
  fields._fibers_id = 'source-' .. tostring(next_id)
  fields._fibers_kind = SourceKind
  local source = setmetatable(fields, Source)

  if kind == 'signal' then
    source._validity = Validity.signal(source.name)
  elseif kind == 'queue' then
    source._validity = Validity.queue(source.name)
  elseif kind == 'readiness' then
    source._validity = Validity.level(source.name)
  elseif kind == 'clock' then
    source._validity = Validity.clock(source.name or 'clock')
  end
  return source
end

local function runtime_now(ctx)
  local rt = ctx and ctx.rt
  if rt and rt.now then return rt:now() end
  return 0
end

local function queue_count(source) return source._validity:count() end
local function queue_head_index(source) return source._validity.head or 1 end

local function ensure_source(c, source)
  local rec = Resource.ensure(c, source, SourceKind)
  rec.take = rec.take or 0
  return rec
end

function SourceKind.clone(rec)
  return { kind = SourceKind, take = rec.take or 0, head = rec.head }
end

function SourceKind.merge_seq(dst, src)
  if src.head ~= nil and dst.head == nil then dst.head = src.head end
  dst.take = (dst.take or 0) + (src.take or 0)
  return true
end

function SourceKind.merge_par(dst, src)
  if src.head ~= nil and dst.head == nil then dst.head = src.head end
  if (dst.take or 0) > 0 and (src.take or 0) > 0 then return false, 'source-queue-parallel-consume-conflict' end
  dst.take = (dst.take or 0) + (src.take or 0)
  return true
end

function SourceKind.project(source, rec, query)
  if source.kind ~= 'queue' then return nil, false end
  local take = rec and rec.take or 0
  if query == 'count' then return queue_count(source) - take, true end
  if query == 'next' then return source._validity:peek(nil, take), true end
  return nil, false
end

function SourceKind.prepare(source, rec, _resolve)
  local take = rec.take or 0
  if take <= 0 then return nil, nil, true end
  if source.kind ~= 'queue' then return nil, 'source-consume-non-queue' end
  if rec.head ~= nil and queue_head_index(source) ~= rec.head then return nil, 'stale' end
  if queue_count(source) < take then return nil, 'stale' end
  return { kind = SourceKind, resource = source, take = take, head = rec.head or queue_head_index(source) }
end

function SourceKind.apply(prepared, _log)
  local ok, err = prepared.resource._validity:take(prepared.take or 0, 'queue head consumed')
  if not ok then error(err or 'queue consume failed') end
end

local function signal_wait(source, payload, ctx)
  local vals, ready = source._validity:get(ctx)
  if ready then return Result.ready(Proposal.new(vals or OpPack(true))) end
  return Result.wait(Wait.source(source, payload.interest or 'ready', { kind = 'signal' }))
end

local function queue_next(source, _payload, ctx)
  local overlay = ctx and ctx.overlay
  local orec = overlay and overlay.res and overlay.res[source]
  local take = orec and orec.take or 0
  local value = source._validity:peek(ctx, take)
  if value == nil then return Result.wait(Wait.source(source, 'next', { kind = 'queue' })) end
  local c = Proposal.new(value)
  local r = ensure_source(c, source)
  r.head = r.head or queue_head_index(source)
  r.take = (r.take or 0) + 1
  return Result.ready(c)
end

function SourceKind.eval(source, payload, ctx)
  local op = payload.op
  if op ~= 'wait' and op ~= 'until' and op ~= 'next' then error('unknown source command ' .. tostring(op), 2) end

  if source.kind == 'signal' then
    if op ~= 'wait' then error('signal sources support wait_op, not next_op', 2) end
    return signal_wait(source, payload, ctx)
  elseif source.kind == 'queue' then
    if op ~= 'next' then error('queue sources support next_op, not wait_op', 2) end
    return queue_next(source, payload, ctx)
  elseif source.kind == 'clock' then
    local deadline = payload.deadline
    local now = (ctx and ctx.now and ctx:now()) or runtime_now(ctx)
    if now >= deadline then return Result.ready(Proposal.new(OpPack(true, now))) end
    if ctx and ctx.rt then
      ctx.rt._clock_sources = ctx.rt._clock_sources or setmetatable({}, { __mode = 'k' })
      ctx.rt._clock_sources[source] = true
    end
    source._validity:observe_before(ctx, deadline)
    return Result.wait(Wait.time(deadline, source))
  elseif source.kind == 'readiness' then
    if op ~= 'wait' then error('readiness sources support wait_op/readable_op/writable_op', 2) end
    local mode = normalise_readiness_mode(payload.mode or source.mode or 'read')
    local key = payload.key or source.key
    if source._validity:get(ctx, mode) then return Result.ready(Proposal.new(OpPack(true, key, mode))) end
    return Result.wait(Wait.source(source, tostring(mode) .. ':' .. tostring(key), { kind = 'readiness', key = key, mode = mode }))
  end

  error('unknown source kind ' .. tostring(source.kind), 2)
end


function SourceKind.absence(source, payload, ctx)
  local op = payload and payload.op
  if source.kind == 'signal' and op == 'wait' then
    local _, ready = source._validity:get(ctx)
    if not ready then
      local frontier = source._validity:frontier_for('signal.state')
      if ctx and ctx.add then ctx:add({ kind = 'signal-absent', source = source, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
      return true
    end
  elseif source.kind == 'queue' and op == 'next' then
    if source._validity:peek(ctx, 0) == nil then
      local frontier = source._validity:frontier_for('queue.empty')
      if ctx and ctx.add then ctx:add({ kind = 'queue-empty', source = source, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
      return true
    end
  elseif source.kind == 'clock' and op == 'until' then
    local deadline = payload.deadline
    local now = (ctx and ctx.now and ctx:now()) or runtime_now(ctx)
    if now < deadline then
      if ctx and ctx.rt then
        ctx.rt._clock_sources = ctx.rt._clock_sources or setmetatable({}, { __mode = 'k' })
        ctx.rt._clock_sources[source] = true
      end
      source._validity:observe_before(ctx, deadline)
      local frontier = source._validity:before_frontier(deadline)
      if ctx and ctx.add then ctx:add({ kind = 'clock-before', source = source, deadline = deadline, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
      return true
    end
  elseif source.kind == 'readiness' and op == 'wait' then
    local mode = normalise_readiness_mode(payload.mode or source.mode or 'read')
    if not source._validity:get(ctx, mode) then
      local frontier = source._validity:frontier_for('readiness', mode)
      if ctx and ctx.add then ctx:add({ kind = 'readiness-absent', source = source, mode = mode, frontier = frontier, stamp = frontier and frontier.gen or nil }) end
      return true
    end
  end
  return false
end

function SourceKind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
end

function Source.signal(name) return new_source('signal', { name = name }) end
function Source.queue(name) return new_source('queue', { name = name }) end
function Source.clock(name) return new_source('clock', { name = name or 'clock' }) end
function Source.readiness(key, mode, name) return new_source('readiness', { key = key, mode = normalise_readiness_mode(mode or 'read'), name = name }) end

function Source:wait_op()
  if self.kind == 'signal' then return DefaultOp._resource(self, SourceKind, { op = 'wait', interest = 'ready' }) end
  if self.kind == 'readiness' then return self:readiness_op(self.mode or 'read') end
  error('wait_op is not supported by ' .. tostring(self.kind) .. ' source', 2)
end
function Source:next_op()
  if self.kind == 'queue' then return DefaultOp._resource(self, SourceKind, { op = 'next', interest = 'next' }) end
  error('next_op is not supported by ' .. tostring(self.kind) .. ' source', 2)
end
function Source:at_op(deadline)
  if self.kind ~= 'clock' then error('at_op is only supported by clock sources', 2) end
  return DefaultOp._resource(self, SourceKind, { op = 'until', deadline = deadline })
end
function Source:readiness_op(mode)
  if self.kind ~= 'readiness' then error('readiness_op is only supported by readiness sources', 2) end
  return DefaultOp._resource(self, SourceKind, { op = 'wait', key = self.key, mode = normalise_readiness_mode(mode or self.mode or 'read') })
end
function Source:readable_op() return self:readiness_op('read') end
function Source:writable_op() return self:readiness_op('write') end

Source.Kind = SourceKind
return Source
