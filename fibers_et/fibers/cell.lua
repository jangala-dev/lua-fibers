-- Transactional Cell.
--
-- A Cell is the public low-level state primitive.  It is a transactional fact:
-- reads observe the candidate-world overlay, writes are journalled, and waits
-- produce typed wait interests.  State-changing commits publish a standard wake
-- Effect, so hosts can retry relevant waits without knowing Cell internals.

local Resource = require('fibers.resources.protocol')
local Candidate = require('fibers.algebra.candidate')
local Result = require('fibers.algebra.result')
local DefaultOp = require('fibers.op')
local Wait = require('fibers.wait')
local OpPack = DefaultOp._pack

local Cell = {}
Cell.__index = Cell

local CellKind = { name = 'cell' }
local next_id = 0

local function is_op_module(x)
  return type(x) == 'table' and type(x._resource) == 'function'
end

local function op_arg(a, b)
  if is_op_module(a) then return a, b end
  return DefaultOp, a
end

local function merge_read(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
end

local function read_record(c, cell)
  local rec = Resource.ensure(c, cell, CellKind)
  rec.read = rec.read or (cell.version or 0)
  return rec
end

local function write_record(c, cell, value, mode)
  local rec = read_record(c, cell)
  rec.has_write = true
  rec.write = value
  rec.mode = mode
  return rec
end

function CellKind.clone(rec)
  return { kind = CellKind, read = rec.read, has_write = rec.has_write, write = rec.write, mode = rec.mode }
end

function CellKind.merge_seq(dst, src)
  merge_read(dst, src)
  if src.has_write then dst.has_write = true; dst.write = src.write; dst.mode = src.mode end
  return true
end

function CellKind.merge_par(dst, src)
  merge_read(dst, src)
  if src.has_write then
    if dst.has_write then
      if not (dst.mode == 'set' and src.mode == 'set' and dst.write == src.write) then
        return false, 'cell-conflict'
      end
    else
      dst.has_write = true; dst.write = src.write; dst.mode = src.mode
    end
  end
  return true
end

function CellKind.project(cell, rec, query)
  if query ~= 'value' then return nil, false end
  if rec and rec.has_write then return rec.write, true end
  return cell.value, true
end

function CellKind.prepare(cell, rec, resolve)
  if rec.read ~= nil and (cell.version or 0) ~= rec.read then return nil, 'stale' end
  if rec.has_write then
    return { kind = CellKind, resource = cell, write = resolve(rec.write) }
  end
  return nil, nil, true
end

function CellKind.apply(prepared, _log)
  local cell = prepared.resource
  cell.value = prepared.write
  cell.version = (cell.version or 0) + 1
end

function CellKind.eval(cell, payload, ctx)
  local op = payload.op
  if op == 'get' then
    local c = Candidate.new(OpPack(Resource.project(ctx, cell, 'value')))
    read_record(c, cell)
    return Result.cands({ c })
  elseif op == 'set' then
    local c = Candidate.new(OpPack(true))
    write_record(c, cell, payload.value, 'set')
    return Result.cands({ c })
  elseif op == 'update' then
    local old = Resource.project(ctx, cell, 'value')
    local new = payload.fn(old)
    local c = Candidate.new(OpPack(new, old))
    write_record(c, cell, new, 'update')
    return Result.cands({ c })
  elseif op == 'wait_until' then
    local value = Resource.project(ctx, cell, 'value')
    if payload.predicate(value) then
      local c = Candidate.new(OpPack(value))
      read_record(c, cell)
      return Result.cands({ c })
    end
    return Result.wait(Wait.resource('cell', cell._fibers_id, cell, { op = 'wait_until' }))
  elseif op == 'modify_when' then
    local old = Resource.project(ctx, cell, 'value')
    if not payload.predicate(old) then
      return Result.wait(Wait.resource('cell', cell._fibers_id, cell, { op = 'modify_when' }))
    end
    local new = payload.update(old)
    local c = Candidate.new(OpPack(new, old))
    write_record(c, cell, new, 'modify_when')
    return Result.cands({ c })
  end
  error('unknown cell operation ' .. tostring(op), 2)
end

function CellKind.summary(payload, out)
  out.resources = true
  out.closed = false
  local op = payload and payload.op
  if op == 'get' then out.reads = true end
  if op == 'set' or op == 'update' or op == 'modify_when' then out.writes = true end
  if op == 'wait_until' or op == 'modify_when' then out.dynamic = true end
end

function Cell.new(value, name)
  next_id = next_id + 1
  return setmetatable({ value = value, version = 0, name = name or ('cell-' .. tostring(next_id)), _fibers_id = 'cell-' .. tostring(next_id), _fibers_kind = CellKind, _fibers_value = true }, Cell)
end

function Cell:get_op(Op)
  Op = is_op_module(Op) and Op or DefaultOp
  return Op._resource(self, CellKind, { op = 'get' })
end

function Cell:set_op(a, b)
  local Op, value = op_arg(a, b)
  return Op._resource(self, CellKind, { op = 'set', value = value })
end

function Cell:update_op(a, b)
  local Op, fn = op_arg(a, b)
  return Op._resource(self, CellKind, { op = 'update', fn = fn })
end

function Cell:wait_op(a, b)
  local Op, predicate = op_arg(a, b)
  predicate = predicate or function(v) return not not v end
  return Op._resource(self, CellKind, { op = 'wait_until', predicate = predicate })
end

Cell.wait_until_op = Cell.wait_op

function Cell:modify_when_op(a, b, c)
  local Op, predicate, update
  if is_op_module(a) then Op, predicate, update = a, b, c else Op, predicate, update = DefaultOp, a, b end
  return Op._resource(self, CellKind, { op = 'modify_when', predicate = predicate, update = update })
end

Cell.Kind = CellKind
return Cell
