-- Open-world resource participation tests.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

local Op = require('fibers.base.op')
local Runtime = require('fibers.kernel.runtime')
local Resource = require('fibers.kernel.resources.protocol')
local Proposal = require('fibers.kernel.resources.proposal')
local Result = require('fibers.kernel.resources.result')

local pack_ = Op._pack

local BoxKind = { name = 'example-box' }

local function read_rec(c, box)
  local rec = Resource.ensure(c, box, BoxKind)
  rec.read = rec.read or box.version
  return rec
end

function BoxKind.clone(rec)
  return { kind = BoxKind, read = rec.read, has_write = rec.has_write, write = rec.write }
end

function BoxKind.merge_seq(dst, src)
  dst.read = dst.read or src.read
  if src.has_write then dst.has_write, dst.write = true, src.write end
  return true
end

function BoxKind.merge_par(dst, src)
  dst.read = dst.read or src.read
  if src.has_write then
    if dst.has_write and dst.write ~= src.write then return false, 'box-conflict' end
    dst.has_write, dst.write = true, src.write
  end
  return true
end

function BoxKind.project(box, rec, query)
  if query ~= 'value' then return nil, false end
  if rec and rec.has_write then return rec.write, true end
  return box.value, true
end

function BoxKind.prepare(box, rec)
  if rec.read ~= box.version then return nil, 'stale' end
  if rec.has_write then return { kind = BoxKind, resource = box, write = rec.write } end
  return nil, nil, true
end

function BoxKind.apply(p, _log)
  p.resource.value = p.write
  p.resource.version = p.resource.version + 1
end

function BoxKind.eval(box, payload, ctx)
  if payload.op == 'get' then
    local c = Proposal.new(pack_(Resource.project(ctx, box, 'value')))
    read_rec(c, box)
    return Result.ready(c)
  elseif payload.op == 'set' then
    local c = Proposal.new(pack_(true))
    local rec = read_rec(c, box)
    rec.has_write, rec.write = true, payload.value
    return Result.ready(c)
  end
  error('unknown box operation')
end

local Box = {}
Box.__index = Box
function Box.new(v) return setmetatable({ value = v, version = 0, _fibers_id = {}, _fibers_kind = BoxKind }, Box) end
function Box:get_op() return Op._resource(self, BoxKind, { op = 'get' }) end
function Box:set_op(v) return Op._resource(self, BoxKind, { op = 'set', value = v }) end

local box = Box.new(0)
local rt = Runtime.new()
local got
rt:spawn_raw(function()
  got = rt:perform(box:set_op(7):and_then(function() return box:get_op() end))
end, 'open-box')

local st = rt:run()
if not st or st.tag ~= 'found' then error('expected found') end
if got ~= 7 or box.value ~= 7 then error('open resource failed') end

print('tests/test_open_resources.lua: box resource ok')

print('tests/test_open_resources.lua: ok')
