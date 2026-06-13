-- Transactional byte storage for Flow.
--
-- ByteBuffer is intentionally only byte storage. It knows how to append,
-- inspect, scan, and consume committed bytes. It does not know about producer
-- or consumer shutdown, capacity, host claims, pumps, EOF, or stream settlement.

local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local Versioned = require('fibers.kernel.resources.versioned')
local Errors = require('fibers.facility.flow.errors')

local OpPack = Op._pack
local Buffer = {}
Buffer.__index = Buffer
local BufferKind = { name = 'flow_buffer' }

local COALESCE_LIMIT = 8192
local COMPACT_AFTER = 32
local next_id = 0

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then error('Flow bytes must be a string', 3) end
  return bytes
end

local function as_nonneg_int(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'Flow byte count') .. ' must be a non-negative integer', 3)
  end
  return n
end

local function clone_ops(ops)
  local out = {}
  for i = 1, #(ops or {}) do
    local c = {}
    for k, v in pairs(ops[i]) do c[k] = v end
    out[i] = c
  end
  return out
end

local function compact_chunks(buf)
  local first = buf.head_chunk or 1
  if first <= COMPACT_AFTER then return end
  local chunks, out = buf.chunks or {}, {}
  for i = first, #chunks do out[#out + 1] = chunks[i] end
  buf.chunks = out
  buf.head_chunk = 1
end

local function append_chunk(buf, bytes)
  if bytes == '' then return end
  local chunks = buf.chunks
  local last = chunks[#chunks]
  if last and #last + #bytes <= COALESCE_LIMIT then
    chunks[#chunks] = last .. bytes
  else
    chunks[#chunks + 1] = bytes
  end
  buf.length = (buf.length or 0) + #bytes
end

local function peek_bytes(buf, n)
  n = math.min(n or buf.length or 0, buf.length or 0)
  if n <= 0 then return '' end
  local out, remaining = {}, n
  local idx = buf.head_chunk or 1
  local off = buf.head_offset or 1
  local chunks = buf.chunks or {}
  while remaining > 0 do
    local chunk = chunks[idx]
    if not chunk then break end
    local avail = #chunk - off + 1
    if avail > 0 then
      local take = math.min(avail, remaining)
      out[#out + 1] = string.sub(chunk, off, off + take - 1)
      remaining = remaining - take
    end
    idx = idx + 1
    off = 1
  end
  return table.concat(out)
end

local function consume_bytes(buf, n)
  n = math.min(n or 0, buf.length or 0)
  if n <= 0 then return '' end
  local out = peek_bytes(buf, n)
  local remaining = n
  local chunks = buf.chunks
  while remaining > 0 do
    local idx = buf.head_chunk or 1
    local chunk = chunks[idx]
    if not chunk then break end
    local off = buf.head_offset or 1
    local avail = #chunk - off + 1
    local take = math.min(avail, remaining)
    remaining = remaining - take
    if take == avail then
      buf.head_chunk = idx + 1
      buf.head_offset = 1
    else
      buf.head_offset = off + take
    end
  end
  buf.length = (buf.length or 0) - n
  if buf.length <= 0 then
    buf.length = 0
    buf.chunks = {}
    buf.head_chunk = 1
    buf.head_offset = 1
  else
    compact_chunks(buf)
  end
  return out
end

local function view_from_buffer(b)
  local chunks = {}
  local bchunks = b.chunks or {}
  local first = b.head_chunk or 1
  for i = first, #bchunks do chunks[#chunks + 1] = bchunks[i] end
  return { chunks = chunks, head_chunk = 1, head_offset = b.head_offset or 1, length = b.length or 0, version = b.version or 0 }
end

local function apply_view_op(view, op)
  if op.kind == 'append' then append_chunk(view, op.bytes or '')
  elseif op.kind == 'consume' then consume_bytes(view, op.n or 0)
  end
end

local function projected_view(b, rec)
  local v = view_from_buffer(b)
  for i = 1, #(rec and rec.ops or {}) do apply_view_op(v, rec.ops[i]) end
  return v
end

local function ctx_view(ctx, b)
  local rec = Versioned.overlay_rec(ctx, b)
  return projected_view(b, rec), rec
end

local function state_table(b, view)
  return {
    buffer = b,
    length = view.length or 0,
    data = peek_bytes(view, view.length or 0),
    chunk_count = #(view.chunks or {}),
    version = view.version or 0,
  }
end

local function scan_table(b, view, sep, limit)
  local data = peek_bytes(view, view.length or 0)
  local pos = sep and string.find(data, sep, 1, true) or nil
  local length = view.length or 0
  return {
    buffer = b,
    data = data,
    length = length,
    sep = sep,
    pos = pos,
    found = pos ~= nil,
    limited = limit ~= nil and ((pos and (pos - 1) or length) > limit),
    version = view.version or 0,
  }
end

local function ensure_record(c, b, version)
  local rec = Versioned.ensure(c, b, BufferKind, version)
  rec.ops = rec.ops or {}
  return rec
end

local function add_op(c, b, op, version)
  local rec = ensure_record(c, b, version)
  rec.ops[#rec.ops + 1] = op
  return rec
end

local function read_only(b, version, ...)
  return Versioned.read_only(b, BufferKind, version, OpPack, ...)
end

local function wake_set(b, changed)
  if not changed then return nil end
  return Versioned.wake_set('flow:buffer:changed', b._fibers_id, { buffer = b })
end

function BufferKind.clone(rec)
  return { kind = BufferKind, read = rec.read, ops = clone_ops(rec.ops) }
end

function BufferKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  dst.ops = dst.ops or {}
  for i = 1, #(src.ops or {}) do dst.ops[#dst.ops + 1] = src.ops[i] end
  return true
end

function BufferKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  local a, b = #(dst.ops or {}), #(src.ops or {})
  if a > 0 and b > 0 then return false, Errors.BUFFER_PARALLEL_CONFLICT end
  if b > 0 then
    dst.ops = dst.ops or {}
    for i = 1, b do dst.ops[#dst.ops + 1] = src.ops[i] end
  end
  return true
end

function BufferKind.project(buffer, rec, query)
  local v = projected_view(buffer, rec)
  if query == 'snapshot' or query == 'state' then return state_table(buffer, v), true end
  if query == 'length' then return v.length or 0, true end
  if query == 'data' then return peek_bytes(v, v.length or 0), true end
  return nil, false
end

function BufferKind.prepare(buffer, rec, resolve)
  if rec.read ~= nil and (buffer.version or 0) ~= rec.read then return nil, 'stale' end
  local ops = rec.ops or {}
  if #ops == 0 then return nil, nil, true end
  local v = view_from_buffer(buffer)
  local prepared_ops = {}
  for i = 1, #ops do
    local op = {}
    for k, val in pairs(ops[i]) do op[k] = val end
    if op.bytes ~= nil then op.bytes = resolve(op.bytes) end
    if op.kind == 'consume' and (op.n or 0) > (v.length or 0) then return nil, Errors.UNDERFLOW end
    if op.kind ~= 'append' and op.kind ~= 'consume' then return nil, Errors.BUFFER_UNKNOWN_OP end
    prepared_ops[#prepared_ops + 1] = op
    apply_view_op(v, op)
  end
  local set, err = wake_set(buffer, true)
  if err then return nil, err end
  return { kind = BufferKind, resource = buffer, ops = prepared_ops, consequence_set = set }
end

function BufferKind.apply(prepared, _log)
  local b = prepared.resource
  local view = { chunks = b.chunks or {}, head_chunk = b.head_chunk or 1, head_offset = b.head_offset or 1, length = b.length or 0 }
  for i = 1, #(prepared.ops or {}) do apply_view_op(view, prepared.ops[i]) end
  b.chunks = view.chunks
  b.head_chunk = view.head_chunk
  b.head_offset = view.head_offset
  b.length = view.length
  b.version = (b.version or 0) + 1
end

function BufferKind.eval(buffer, payload, ctx)
  local op = payload.op
  local version = Versioned.observe(ctx, buffer)
  local view = ctx_view(ctx, buffer)
  if op == 'append' then
    local bytes = as_bytes(payload.bytes or '')
    if bytes == '' then return Result.cands({ read_only(buffer, version, 0) }) end
    local c = Candidate.new(OpPack(#bytes))
    add_op(c, buffer, { kind = 'append', bytes = bytes }, version)
    return Result.cands({ c })
  elseif op == 'consume' then
    local n = as_nonneg_int(payload.n, 0, 'Flow consume size')
    if n > (view.length or 0) then return Result.cands({ read_only(buffer, version, nil, Errors.UNDERFLOW) }) end
    local bytes = peek_bytes(view, n)
    local c = Candidate.new(OpPack(bytes))
    add_op(c, buffer, { kind = 'consume', n = n }, version)
    return Result.cands({ c })
  elseif op == 'peek' then
    local n = as_nonneg_int(payload.n, view.length or 0, 'Flow peek size')
    return Result.cands({ read_only(buffer, version, { buffer = buffer, data = peek_bytes(view, math.min(n, view.length or 0)), length = view.length or 0, version = view.version or version }) })
  elseif op == 'length' then
    return Result.cands({ read_only(buffer, version, { buffer = buffer, length = view.length or 0, version = view.version or version }) })
  elseif op == 'scan' then
    return Result.cands({ read_only(buffer, version, scan_table(buffer, view, payload.sep, payload.limit)) })
  elseif op == 'state' then
    return Result.cands({ read_only(buffer, version, state_table(buffer, view)) })
  elseif op == 'changed' then
    if version ~= payload.version then return Result.cands({ read_only(buffer, version, state_table(buffer, view)) }) end
    return Result.wait(Wait.resource('flow:buffer:changed', buffer._fibers_id, buffer, { op = 'changed', version = payload.version }))
  end
  error('unknown Flow buffer operation ' .. tostring(op), 2)
end

function BufferKind.summary(_payload, out)
  out.resources = true; out.dynamic = true; out.closed = false
end

function Buffer.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'flow-buffer-' .. tostring(next_id)
  local b = setmetatable({
    chunks = {}, head_chunk = 1, head_offset = 1, length = 0, version = 0,
    name = opts.name or id, _fibers_id = id, _fibers_kind = BufferKind,
  }, Buffer)
  if opts.data then append_chunk(b, as_bytes(opts.data)) end
  return b
end

function Buffer:append_op(bytes) return Op._resource(self, BufferKind, { op = 'append', bytes = as_bytes(bytes or '') }) end
function Buffer:consume_op(n) return Op._resource(self, BufferKind, { op = 'consume', n = as_nonneg_int(n, 0, 'Flow consume size') }) end
function Buffer:peek_op(n)
  if n ~= nil then n = as_nonneg_int(n, nil, 'Flow peek size') end
  return Op._resource(self, BufferKind, { op = 'peek', n = n })
end
function Buffer:length_op() return Op._resource(self, BufferKind, { op = 'length' }) end
function Buffer:scan_op(opts)
  opts = opts or {}
  local sep = opts.sep
  if sep ~= nil and (type(sep) ~= 'string' or sep == '') then error('Flow scan separator must be a non-empty string', 2) end
  local limit = opts.limit
  if limit ~= nil then limit = as_nonneg_int(limit, nil, 'Flow scan limit') end
  return Op._resource(self, BufferKind, { op = 'scan', sep = sep, limit = limit })
end
function Buffer:state_op() return Op._resource(self, BufferKind, { op = 'state' }) end
function Buffer:changed_op(version) return Op._resource(self, BufferKind, { op = 'changed', version = version }) end
function Buffer:debug_data() return peek_bytes(view_from_buffer(self), self.length or 0) end

Buffer.Kind = BufferKind
return Buffer
