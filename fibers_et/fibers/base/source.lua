-- Public transactional Source.
--
-- A Source brings host, time, or external facts into the Op algebra.  It is the
-- dual of Effect: Sources make outside facts waitable; Effects publish
-- committed obligations outwards.
--
-- Source consumers do not mutate.  External mutation goes through Runtime-bound
-- producer capabilities returned by Runtime:signal(), Runtime:queue_source(), or
-- Runtime:readiness(), or through Runtime:arrive(source, ...).
--
-- Source has two ordinary disciplines:
--   signal : a latched current fact, observed by wait_op()
--   queue  : a stream of occurrences, consumed transactionally by next_op()
--   readiness : level-like host readiness hints, observed by mode-specific ops

local DefaultOp = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local OpPack = DefaultOp._pack

local Source = {}
Source.__index = Source

local SourceKind = { name = 'source' }
local next_id = 0


local function new_source(kind, fields)
  next_id = next_id + 1
  fields = fields or {}
  fields.kind = kind
  fields.name = fields.name or (kind .. '-' .. tostring(next_id))
  fields.version = fields.version or 0
  fields._fibers_id = 'source-' .. tostring(next_id)
  fields._fibers_kind = SourceKind
  return setmetatable(fields, Source)
end

local function runtime_now(ctx)
  local rt = ctx and ctx.rt
  if rt and rt.now then return rt:now() end
  return 0
end

local function normalise_readiness_mode(mode)
  mode = mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then error('readiness mode must be read or write', 3) end
  return mode
end

local function readiness_is_set(source, mode)
  mode = normalise_readiness_mode(mode or source.mode or 'read')
  if type(source.ready) == 'table' then return source.ready[mode] == true end
  return source.ready == true and mode == normalise_readiness_mode(source.mode or 'read')
end

local function queue_head_index(source)
  return source.head or 1
end

local function queue_tail_index(source)
  return source.tail or 0
end

local function queue_count(source)
  local n = queue_tail_index(source) - queue_head_index(source) + 1
  return n > 0 and n or 0
end

local function ensure_source(c, source, version)
  local rec = Resource.ensure(c, source, SourceKind)
  rec.read = rec.read or (version or source.version or 0)
  rec.take = rec.take or 0
  return rec
end

function SourceKind.clone(rec)
  return { kind = SourceKind, read = rec.read, take = rec.take or 0 }
end

function SourceKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  dst.take = (dst.take or 0) + (src.take or 0)
  return true
end

function SourceKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  if (dst.take or 0) > 0 and (src.take or 0) > 0 then
    return false, 'source-queue-parallel-consume-conflict'
  end
  dst.take = (dst.take or 0) + (src.take or 0)
  return true
end

function SourceKind.project(source, rec, query)
  if source.kind ~= 'queue' then return nil, false end
  if query == 'count' then
    return queue_count(source) - (rec and rec.take or 0), true
  elseif query == 'next' then
    local idx = queue_head_index(source) + (rec and rec.take or 0)
    if idx <= queue_tail_index(source) then return source.queue[idx], true end
    return nil, true
  end
  return nil, false
end

function SourceKind.prepare(source, rec, _resolve)
  if rec.read ~= nil and (source.version or 0) ~= rec.read then return nil, 'stale' end
  local take = rec.take or 0
  if take <= 0 then return nil, nil, true end
  if source.kind ~= 'queue' then return nil, 'source-consume-non-queue' end
  if queue_count(source) < take then return nil, 'stale' end
  return { kind = SourceKind, resource = source, take = take }
end

function SourceKind.apply(prepared, _log)
  local source = prepared.resource
  local take = prepared.take or 0
  if take <= 0 then return end
  source.head = (source.head or 1) + take
  if source.head > (source.tail or 0) then
    source.queue = {}
    source.head = 1
    source.tail = 0
  end
  source.version = (source.version or 0) + 1
end

local function observe_version(ctx, obj)
  if ctx then
    local f = ctx.observe_version
    if f then return f(ctx, obj) end
  end
  return obj.version or 0
end

local function before(ctx, deadline)
  if ctx then
    local f = ctx.before
    if f then f(ctx, deadline) end
  end
  return deadline
end

local function observed_now(ctx)
  if ctx then
    local f = ctx.now
    if f then return f(ctx) end
  end
  return runtime_now(ctx)
end

local function signal_wait(source, payload, ctx)
  observe_version(ctx, source)
  if source.ready then return Result.cands({ Candidate.new(source.vals or OpPack(true)) }) end
  return Result.wait(Wait.source(source, payload.interest or 'ready', { kind = 'signal' }))
end

local function queue_next(source, _payload, ctx)
  local version = observe_version(ctx, source)
  local value = Resource.project(ctx, source, 'next')
  if value == nil then
    return Result.wait(Wait.source(source, 'next', { kind = 'queue' }))
  end
  local c = Candidate.new(value)
  local rec = ensure_source(c, source, version)
  rec.take = (rec.take or 0) + 1
  return Result.cands({ c })
end

function SourceKind.eval(source, payload, ctx)
  local op = payload.op
  if op ~= 'wait' and op ~= 'until' and op ~= 'next' then error('unknown source operation ' .. tostring(op), 2) end

  if source.kind == 'signal' then
    if op ~= 'wait' then error('signal sources support wait_op, not next_op', 2) end
    return signal_wait(source, payload, ctx)
  elseif source.kind == 'queue' then
    if op ~= 'next' then error('queue sources support next_op, not wait_op', 2) end
    return queue_next(source, payload, ctx)
  elseif source.kind == 'clock' then
    local deadline = payload.deadline
    local now = observed_now(ctx)
    if now >= deadline then return Result.cands({ Candidate.new(OpPack(true, now)) }) end
    before(ctx, deadline)
    return Result.wait(Wait.time(deadline, source))
  elseif source.kind == 'readiness' then
    if op ~= 'wait' then error('readiness sources support wait_op/readable_op/writable_op', 2) end
    local mode = normalise_readiness_mode(payload.mode or source.mode or 'read')
    local key = payload.key or source.key
    observe_version(ctx, source)
    if readiness_is_set(source, mode) then return Result.cands({ Candidate.new(OpPack(true, key, mode)) }) end
    return Result.wait(Wait.source(source, tostring(mode) .. ':' .. tostring(key), { kind = 'readiness', key = key, mode = mode }))
  end

  error('unknown source kind ' .. tostring(source.kind), 2)
end

function SourceKind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
end

function Source.signal(name)
  return new_source('signal', { name = name, ready = false, vals = nil })
end

function Source.queue(name)
  return new_source('queue', { name = name, queue = {}, head = 1, tail = 0 })
end

function Source.clock(name)
  return new_source('clock', { name = name or 'clock' })
end

function Source.readiness(key, mode, name)
  return new_source('readiness', { key = key, mode = normalise_readiness_mode(mode or 'read'), name = name, ready = {} })
end

function Source:wait_op()
  if self.kind == 'signal' then
    return DefaultOp._resource(self, SourceKind, { op = 'wait', interest = 'ready' })
  elseif self.kind == 'readiness' then
    return self:readiness_op(self.mode or 'read')
  end
  error('wait_op is not supported by ' .. tostring(self.kind) .. ' source', 2)
end

function Source:next_op()
  if self.kind == 'queue' then
    return DefaultOp._resource(self, SourceKind, { op = 'next', interest = 'next' })
  end
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

function Source:readable_op()
  return self:readiness_op('read')
end

function Source:writable_op()
  return self:readiness_op('write')
end



Source.Kind = SourceKind
return Source
