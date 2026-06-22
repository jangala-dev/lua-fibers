-- Transactional Cell.
--
-- A Cell is the public low-level state primitive. It is a transactional fact:
-- reads observe the candidate-world overlay and writes are journalled. Cell
-- primitives do not run user Lua. Selection and interpretation belong in the Op
-- algebra; fixed state transitions belong in specialised resources.

local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')
local Op = require('fibers.base.op')
local Wait = require('fibers.kernel.wait')
local Validity = require('fibers.kernel.validity')
local OpPack = Op._pack

local Cell = {}
Cell.__index = Cell

local CellKind = { name = 'cell' }
local next_id = 0

local function merge_read(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
end

local function read_record(c, cell, version)
  local rec = Resource.ensure(c, cell, CellKind)
  rec.read = rec.read or (version or cell.version or 0)
  return rec
end

local function write_record(c, cell, value, version)
  local rec = read_record(c, cell, version)
  rec.has_write = true
  rec.write = value
  return rec
end

local function projected_version(cell, rec)
  if rec and rec.has_write then return (cell.version or 0) + 1 end
  return cell.version or 0
end


function CellKind.clone(rec)
  return { kind = CellKind, read = rec.read, has_write = rec.has_write, write = rec.write }
end

function CellKind.merge_seq(dst, src)
  merge_read(dst, src)
  if src.has_write then dst.has_write = true; dst.write = src.write end
  return true
end

function CellKind.merge_par(dst, src)
  merge_read(dst, src)
  if src.has_write then
    if dst.has_write then
      if dst.write ~= src.write then return false, 'cell-conflict' end
    else
      dst.has_write = true; dst.write = src.write
    end
  end
  return true
end

function CellKind.project(cell, rec, query)
  if query == 'value' then
    if rec and rec.has_write then return rec.write, true end
    return cell.value, true
  elseif query == 'version' then
    return projected_version(cell, rec), true
  elseif query == 'snapshot' then
    local value = (rec and rec.has_write) and rec.write or cell.value
    return { cell = cell, value = value, version = projected_version(cell, rec), _fibers_cell_snapshot = true }, true
  end
  return nil, false
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
  cell._validity_value:set(prepared.write, 'cell write')
  cell.version = (cell.version or 0) + 1
end

local function observe_version(ctx, obj)
  if ctx then
    local f = ctx.observe_version
    if f then return f(ctx, obj) end
  end
  return obj.version or 0
end

function CellKind.eval(cell, payload, ctx)
  local op = payload.op
  if op == 'read' then
    local version = observe_version(ctx, cell)
    local c = Proposal.new(OpPack(Resource.project(ctx, cell, 'value')))
    read_record(c, cell, version)
    return Result.ready(c)
  elseif op == 'snapshot' then
    local version = observe_version(ctx, cell)
    local c = Proposal.new(OpPack(Resource.project(ctx, cell, 'snapshot')))
    read_record(c, cell, version)
    return Result.ready(c)
  elseif op == 'write' then
    local version = observe_version(ctx, cell)
    local c = Proposal.new(OpPack(true))
    write_record(c, cell, payload.value, version)
    return Result.ready(c)
  elseif op == 'changed' then
    local observed = observe_version(ctx, cell)
    local version = Resource.project(ctx, cell, 'version')
    if version ~= payload.version then
      local c = Proposal.new(OpPack(Resource.project(ctx, cell, 'value'), version))
      read_record(c, cell, observed)
      return Result.ready(c)
    end
    return Result.wait(Wait.resource('cell', cell._fibers_id, cell, { op = 'changed', version = payload.version }))
  end
  error('unknown cell command ' .. tostring(op), 2)
end


function CellKind.absence(cell, payload, ctx)
  if payload and payload.op == 'changed' then
    local version = observe_version(ctx, cell)
    if version == payload.version then
      if ctx and ctx.add then
        local frontier = cell._validity_value and cell._validity_value:frontier_for() or nil
        ctx:add({ kind = 'cell-unchanged', cell = cell, version = version, frontier = frontier, stamp = frontier and frontier.gen or nil })
      end
      return true
    end
  end
  return false
end

function CellKind.summary(payload, out)
  out.resources = true
  out.closed = false
  local op = payload and payload.op
  if op == 'read' or op == 'snapshot' or op == 'changed' then out.reads = true end
  if op == 'write' then out.writes = true end
  if op == 'changed' then out.dynamic = true end
end

function Cell.new(value, name)
  next_id = next_id + 1
  local id = 'cell-' .. tostring(next_id)
  local cell = setmetatable({ value = value, version = 0, name = name or id, _fibers_id = id, _fibers_kind = CellKind }, Cell)
  cell._validity_value = Validity.scalar(value, (cell.name or id) .. ':value', { on_set = function(v) cell.value = v end })
  return cell
end

function Cell:read_op()
  return Op._resource(self, CellKind, { op = 'read' })
end

function Cell:snapshot_op()
  return Op._resource(self, CellKind, { op = 'snapshot' })
end

function Cell:write_op(value)
  return Op._resource(self, CellKind, { op = 'write', value = value })
end

function Cell:changed_op(version)
  return Op._resource(self, CellKind, { op = 'changed', version = version })
end


Cell.Kind = CellKind
return Cell
