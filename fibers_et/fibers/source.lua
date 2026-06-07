-- Public transactional Source.
--
-- A Source brings host, time, or external occurrences into the Op algebra.  It
-- is the dual of Effect: Sources make outside facts waitable; Effects publish
-- committed obligations outwards.

local DefaultOp = require('fibers.op')
local Candidate = require('fibers.algebra.candidate')
local Result = require('fibers.algebra.result')
local Wait = require('fibers.wait')
local OpPack = DefaultOp._pack

local Source = {}
Source.__index = Source

local SourceKind = { name = 'source' }
local next_id = 0

local function is_op_module(x)
  return type(x) == 'table' and type(x._resource) == 'function'
end

local function new_source(kind, fields)
  next_id = next_id + 1
  fields = fields or {}
  fields.kind = kind
  fields.name = fields.name or (kind .. '-' .. tostring(next_id))
  fields._fibers_id = 'source-' .. tostring(next_id)
  fields._fibers_kind = SourceKind
  fields._fibers_value = true
  return setmetatable(fields, Source)
end

local function runtime_now(ctx)
  local rt = ctx and ctx.rt
  if rt and rt.now then return rt:now() end
  return 0
end

local function host_ready(ctx, source, key, mode)
  local rt = ctx and ctx.rt
  if not rt then return false end
  local host = rt.host or {}
  local services = rt.services or {}
  local f = host.source_ready or services.source_ready or host.poll_ready or services.poll_ready or host.ready or services.ready
  if f then return not not f(key, mode, source, rt) end
  return false
end

local function local_ready(source, mode)
  if source.ready == true then return true end
  if type(source.ready) == 'table' then return not not source.ready[mode or source.mode or 'read'] end
  return false
end

function SourceKind.eval(source, payload, ctx)
  local op = payload.op
  if op ~= 'wait' and op ~= 'until' then error('unknown source operation ' .. tostring(op), 2) end

  if source.kind == 'manual' then
    if source.ready then return Result.cands({ Candidate.new(source.vals or OpPack(true)) }) end
    return Result.wait(Wait.source(source, payload.interest or 'ready', { kind = 'manual' }))
  elseif source.kind == 'clock' then
    local deadline = payload.deadline
    local now = runtime_now(ctx)
    if now >= deadline then return Result.cands({ Candidate.new(OpPack(true, now)) }) end
    return Result.wait(Wait.time(deadline, source))
  elseif source.kind == 'readiness' then
    local mode = payload.mode or source.mode or 'read'
    local key = payload.key or source.key
    if local_ready(source, mode) or host_ready(ctx, source, key, mode) then
      return Result.cands({ Candidate.new(OpPack(true, key, mode)) })
    end
    return Result.wait(Wait.source(source, tostring(mode) .. ':' .. tostring(key), { kind = 'readiness', key = key, mode = mode }))
  end

  error('unknown source kind ' .. tostring(source.kind), 2)
end

function SourceKind.summary(_payload, out)
  out.dynamic = true
  out.closed = false
end

function Source.manual(name)
  return new_source('manual', { name = name, ready = false, vals = nil })
end

Source.event = Source.manual

function Source.clock(name)
  return new_source('clock', { name = name or 'clock' })
end

function Source.readiness(key, mode, name)
  return new_source('readiness', { key = key, mode = mode or 'read', name = name, ready = {} })
end

Source.poll = Source.readiness

function Source:next_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  if self.kind == 'manual' or self.kind == 'readiness' then
    return Op._resource(self, SourceKind, { op = 'wait', interest = 'ready', key = self.key, mode = self.mode })
  end
  error('next_op is not supported by ' .. tostring(self.kind) .. ' source', 2)
end

Source.wait_op = Source.next_op

function Source:emit(...)
  if self.kind ~= 'manual' then error('emit is only supported by manual sources', 2) end
  self.ready = true
  self.vals = OpPack(...)
end

Source.set = Source.emit

function Source:clear()
  if self.kind == 'manual' then self.ready = false; self.vals = nil; return end
  if self.kind == 'readiness' then self.ready = {}; return end
end

function Source:at_op(a, b)
  local Op, deadline
  if is_op_module(a) then Op, deadline = a, b else Op, deadline = DefaultOp, a end
  if self.kind ~= 'clock' then error('at_op is only supported by clock sources', 2) end
  return Op._resource(self, SourceKind, { op = 'until', deadline = deadline })
end

function Source:after_op(a, b)
  local Op, delay
  if is_op_module(a) then Op, delay = a, b else Op, delay = DefaultOp, a end
  if self.kind ~= 'clock' then error('after_op is only supported by clock sources', 2) end
  return Op.guard(function(ctx)
    local rt = ctx and ctx.rt
    local now = rt and rt:now() or 0
    return self:at_op(Op, now + delay)
  end)
end

function Source:set_ready(a, b)
  if self.kind ~= 'readiness' then error('set_ready is only supported by readiness sources', 2) end
  if b == nil and type(a) ~= 'string' then
    self.ready[self.mode or 'read'] = not not a
  else
    self.ready[a or self.mode or 'read'] = (b == nil) and true or not not b
  end
end

function Source:clear_ready(mode)
  if self.kind ~= 'readiness' then error('clear_ready is only supported by readiness sources', 2) end
  self.ready[mode or self.mode or 'read'] = nil
end

function Source:readable_op(Op)
  if self.kind ~= 'readiness' then error('readable_op is only supported by readiness sources', 2) end
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, SourceKind, { op = 'wait', key = self.key, mode = 'read' })
end

function Source:writable_op(Op)
  if self.kind ~= 'readiness' then error('writable_op is only supported by readiness sources', 2) end
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, SourceKind, { op = 'wait', key = self.key, mode = 'write' })
end

Source.Kind = SourceKind
return Source
