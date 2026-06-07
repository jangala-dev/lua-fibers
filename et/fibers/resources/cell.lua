local Resource = require('fibers.resources.protocol')
local Candidate = require('fibers.algebra.candidate')
local Result = require('fibers.algebra.result')
local OpPack = require('fibers.op')._pack

local Cell = {}
Cell.__index = Cell

local CellKind = { name = 'cell' }
local next_id = 0

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
  return {
    kind = CellKind,
    read = rec.read,
    has_write = rec.has_write,
    write = rec.write,
    mode = rec.mode,
  }
end

function CellKind.merge_seq(dst, src)
  merge_read(dst, src)
  if src.has_write then
    dst.has_write = true
    dst.write = src.write
    dst.mode = src.mode
  end
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
      dst.has_write = true
      dst.write = src.write
      dst.mode = src.mode
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
    local c = Candidate.new(OpPack(new))
    write_record(c, cell, new, 'update')
    return Result.cands({ c })
  end
  error('unknown cell operation ' .. tostring(op), 2)
end

function CellKind.summary(payload, out)
  out.resources = true
  out.closed = false
  local op = payload and payload.op
  if op == 'get' then out.reads = true end
  if op == 'set' or op == 'update' then out.writes = true end
end

function Cell.new(value, name)
  next_id = next_id + 1
  return setmetatable({ value = value, version = 0, name = name or ('cell-' .. tostring(next_id)), _fibers_id = next_id, _fibers_kind = CellKind }, Cell)
end

function Cell:get_op(Op)
  return Op._resource(self, CellKind, { op = 'get' })
end

function Cell:set_op(Op, value)
  return Op._resource(self, CellKind, { op = 'set', value = value })
end

function Cell:update_op(Op, fn)
  return Op._resource(self, CellKind, { op = 'update', fn = fn })
end

Cell.Kind = CellKind

return Cell
