-- Transactional byte queue resource for stream facilities.
--
-- ByteQueue is deliberately specialised state, not a Cell containing a string.
-- Operations are journalled in candidate worlds. Losing branches consume no
-- bytes, append no bytes, close no halves, and publish no wake effects.
--
-- The committed storage is chunked.  This keeps the stream substrate suitable
-- for real streams later, while preserving a simple transactional view model:
-- speculative views copy chunk references, not the whole committed byte string.

local Op = require('fibers.base.op')
local Resource = require('fibers.kernel.resources.protocol')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local ConsequenceSet = require('fibers.kernel.consequence.set')
local Effect = require('fibers.base.effect')

local OpPack = Op._pack

local ByteQueue = {}
ByteQueue.__index = ByteQueue

local ByteQueueKind = { name = 'byte_queue' }
local next_id = 0

local INF = math.huge
local COALESCE_LIMIT = 8192
local COMPACT_AFTER = 32

local function clone_ops(ops)
  local out = {}
  if ops then
    for i = 1, #ops do
      local op, copy = ops[i], {}
      for k, v in pairs(op) do copy[k] = v end
      out[i] = copy
    end
  end
  return out
end

local function observe_version(ctx, obj)
  if ctx then
    local f = ctx.observe_version
    if f then return f(ctx, obj) end
  end
  return obj.version or 0
end

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then error('stream bytes must be a string', 3) end
  return bytes
end

local function as_nonneg_int(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'stream count') .. ' must be a non-negative integer', 3)
  end
  return n
end

local function validate_sep(sep)
  sep = sep or '\n'
  if type(sep) ~= 'string' or sep == '' then error('stream line separator must be a non-empty string', 3) end
  return sep
end

local function validate_limit(limit)
  if limit == nil then return nil end
  return as_nonneg_int(limit, nil, 'stream line limit')
end

local function ensure_record(c, q, version)
  local rec = Resource.ensure(c, q, ByteQueueKind)
  rec.read = rec.read or (version or q.version or 0)
  rec.ops = rec.ops or {}
  return rec
end

local function add_op(c, q, op, version)
  local rec = ensure_record(c, q, version)
  rec.ops[#rec.ops + 1] = op
  return rec
end

-- Chunk helpers -------------------------------------------------------------

local function q_length(q) return q.length or 0 end

local function view_from_queue(q)
  local chunks = {}
  local qchunks = q.chunks or {}
  local first = q.head_chunk or 1
  for i = first, #qchunks do chunks[#chunks + 1] = qchunks[i] end
  return {
    chunks = chunks,
    head_chunk = 1,
    head_offset = q.head_offset or 1,
    length = q_length(q),
    capacity = q.capacity,
    writer_open = q.writer_open ~= false,
    reader_open = q.reader_open ~= false,
    read_error = q.read_error,
    write_error = q.write_error,
    version = q.version or 0,
  }
end

local function compact_chunks(buf)
  local first = buf.head_chunk or 1
  if first <= COMPACT_AFTER then return end
  local chunks = buf.chunks
  local out = {}
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
  local chunks = buf.chunks
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

local function buffer_to_string(buf, max)
  return peek_bytes(buf, max or (buf.length or 0))
end

local function find_sep_in_buffer(buf, sep, limit)
  local n = buf.length or 0
  if limit ~= nil then n = math.min(n, limit + #sep) end
  local s = buffer_to_string(buf, n)
  return string.find(s, sep, 1, true), s
end

local function free_capacity(view)
  if view.capacity == nil then return INF end
  local n = view.capacity - (view.length or 0)
  return n < 0 and 0 or n
end

local function apply_view_op(view, op)
  local k = op.kind
  if k == 'append' then
    append_chunk(view, op.bytes or '')
  elseif k == 'consume' then
    consume_bytes(view, op.n or 0)
  elseif k == 'close_writer' then
    view.writer_open = false
  elseif k == 'close_reader' then
    view.reader_open = false
  elseif k == 'read_error' then
    view.read_error = op.err
  elseif k == 'write_error' then
    view.write_error = op.err
  end
end

local function projected_view(q, rec)
  local v = view_from_queue(q)
  if rec and rec.ops then
    for i = 1, #rec.ops do apply_view_op(v, rec.ops[i]) end
  end
  return v
end

local function ctx_view(ctx, q)
  local overlay = ctx and ctx.overlay
  local rec = overlay and overlay.res and overlay.res[q]
  return projected_view(q, rec), rec
end

local function state_table(q, view)
  return {
    queue = q,
    length = view.length or 0,
    capacity = view.capacity,
    free = free_capacity(view),
    chunk_count = #(view.chunks or {}),
    writer_open = view.writer_open,
    reader_open = view.reader_open,
    read_error = view.read_error,
    write_error = view.write_error,
    version = view.version,
  }
end

local function read_only(q, version, ...)
  local c = Candidate.new(OpPack(...))
  ensure_record(c, q, version)
  return c
end

local function wait(kind, q, detail)
  return Result.wait(Wait.resource(kind, q._fibers_id, q, detail))
end

local function wake_set(q, readable, writable, drained, changed)
  local set = ConsequenceSet.empty()
  local ok, err
  changed = changed or readable or writable or drained
  if readable then
    ok, err = set:add(Effect.wake('stream:readable', q._fibers_id, { queue = q }))
    if not ok then return nil, err end
  end
  if writable then
    ok, err = set:add(Effect.wake('stream:writable', q._fibers_id, { queue = q }))
    if not ok then return nil, err end
  end
  if drained then
    ok, err = set:add(Effect.wake('stream:drained', q._fibers_id, { queue = q }))
    if not ok then return nil, err end
  end
  if changed then
    ok, err = set:add(Effect.wake('stream:changed', q._fibers_id, { queue = q }))
    if not ok then return nil, err end
  end
  return set
end

-- Resource protocol ---------------------------------------------------------

function ByteQueueKind.clone(rec)
  return { kind = ByteQueueKind, read = rec.read, ops = clone_ops(rec.ops) }
end

function ByteQueueKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  dst.ops = dst.ops or {}
  for i = 1, #(src.ops or {}) do dst.ops[#dst.ops + 1] = src.ops[i] end
  return true
end

function ByteQueueKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  local a = #(dst.ops or {})
  local b = #(src.ops or {})
  if a > 0 and b > 0 then return false, 'byte-queue-parallel-conflict' end
  if b > 0 then
    dst.ops = dst.ops or {}
    for i = 1, b do dst.ops[#dst.ops + 1] = src.ops[i] end
  end
  return true
end

function ByteQueueKind.project(q, rec, query)
  local v = projected_view(q, rec)
  if query == 'state' or query == 'snapshot' then return state_table(q, v), true end
  if query == 'length' then return v.length or 0, true end
  if query == 'free' then return free_capacity(v), true end
  if query == 'data' then return buffer_to_string(v), true end
  if query == 'writer_open' then return v.writer_open, true end
  if query == 'reader_open' then return v.reader_open, true end
  if query == 'closed' then return (not v.writer_open) and (not v.reader_open), true end
  return nil, false
end

local function validate_and_apply_to_view(v, op)
  local k = op.kind
  if k == 'append' then
    local bytes = op.bytes or ''
    if v.write_error then return false, v.write_error end
    if not v.writer_open then return false, 'closed' end
    if not v.reader_open then return false, 'broken_pipe' end
    if #bytes > free_capacity(v) then return false, 'capacity' end
    append_chunk(v, bytes)
    return true
  elseif k == 'consume' then
    local n = op.n or 0
    if n > (v.length or 0) then return false, 'underflow' end
    consume_bytes(v, n)
    return true
  elseif k == 'close_writer' then
    v.writer_open = false
    return true
  elseif k == 'close_reader' then
    v.reader_open = false
    return true
  elseif k == 'read_error' then
    v.read_error = op.err
    return true
  elseif k == 'write_error' then
    v.write_error = op.err
    return true
  end
  return false, 'unknown-byte-queue-op'
end

function ByteQueueKind.prepare(q, rec, resolve)
  if rec.read ~= nil and (q.version or 0) ~= rec.read then return nil, 'stale' end
  local ops = rec.ops or {}
  if #ops == 0 then return nil, nil, true end

  local v = view_from_queue(q)
  local prepared_ops = {}
  local readable, writable, drained, changed = false, false, false, false
  for i = 1, #ops do
    local op = {}
    for k, val in pairs(ops[i]) do op[k] = val end
    if op.bytes ~= nil then op.bytes = resolve(op.bytes) end
    prepared_ops[#prepared_ops + 1] = op
    local before_len = v.length or 0
    local before_writer = v.writer_open
    local before_reader = v.reader_open
    local ok, why = validate_and_apply_to_view(v, op)
    if not ok then return nil, why end
    changed = true
    if op.kind == 'append' and #op.bytes > 0 then readable = true end
    if op.kind == 'consume' and (op.n or 0) > 0 then writable = true end
    if before_len > 0 and (v.length or 0) == 0 then drained = true end
    if op.kind == 'close_writer' and before_writer then readable = true end
    if op.kind == 'close_reader' and before_reader then writable = true end
    if op.kind == 'read_error' then readable = true end
    if op.kind == 'write_error' then writable = true; drained = true end
  end

  local set, err = wake_set(q, readable, writable, drained, changed)
  if err then return nil, err end
  return { kind = ByteQueueKind, resource = q, ops = prepared_ops, consequence_set = set }
end

function ByteQueueKind.apply(prepared, _log)
  local q = prepared.resource
  local qbuf = {
    chunks = q.chunks or {},
    head_chunk = q.head_chunk or 1,
    head_offset = q.head_offset or 1,
    length = q.length or 0,
  }
  for i = 1, #(prepared.ops or {}) do
    local op = prepared.ops[i]
    if op.kind == 'append' then
      append_chunk(qbuf, op.bytes or '')
    elseif op.kind == 'consume' then
      consume_bytes(qbuf, op.n or 0)
    elseif op.kind == 'close_writer' then
      q.writer_open = false
    elseif op.kind == 'close_reader' then
      q.reader_open = false
    elseif op.kind == 'read_error' then
      q.read_error = op.err
    elseif op.kind == 'write_error' then
      q.write_error = op.err
    end
  end
  q.chunks = qbuf.chunks
  q.head_chunk = qbuf.head_chunk
  q.head_offset = qbuf.head_offset
  q.length = qbuf.length
  q.version = (q.version or 0) + 1
end

-- Operation evaluation ------------------------------------------------------

local function eval_append(q, payload, ctx)
  local bytes = as_bytes(payload.bytes or '')
  local v = ctx_view(ctx, q)
  local version = observe_version(ctx, q)
  if #bytes == 0 then return Result.cands({ read_only(q, version, 0) }) end
  if v.write_error then return Result.cands({ read_only(q, version, nil, v.write_error) }) end
  if not v.writer_open then return Result.cands({ read_only(q, version, nil, 'closed') }) end
  if not v.reader_open then return Result.cands({ read_only(q, version, nil, 'broken_pipe') }) end

  local free = free_capacity(v)
  local n
  if payload.some then
    if free <= 0 then return wait('stream:writable', q, { op = 'append_some', need = 'capacity' }) end
    n = math.min(#bytes, free)
  else
    if q.capacity ~= nil and #bytes > q.capacity then return Result.cands({ read_only(q, version, nil, 'too_large') }) end
    if free < #bytes then return wait('stream:writable', q, { op = 'append', need = #bytes }) end
    n = #bytes
  end

  local c = Candidate.new(OpPack(n))
  add_op(c, q, { kind = 'append', bytes = string.sub(bytes, 1, n) }, version)
  return Result.cands({ c })
end

local function eval_consume_some(q, payload, ctx)
  local max = as_nonneg_int(payload.max, 1, 'stream read size')
  local v = ctx_view(ctx, q)
  local version = observe_version(ctx, q)
  if max == 0 then return Result.cands({ read_only(q, version, '') }) end
  if (v.length or 0) > 0 then
    local n = math.min(v.length or 0, max)
    local bytes = peek_bytes(v, n)
    local c = Candidate.new(OpPack(bytes))
    add_op(c, q, { kind = 'consume', n = n }, version)
    return Result.cands({ c })
  end
  if v.read_error then return Result.cands({ read_only(q, version, nil, v.read_error) }) end
  if not v.writer_open then return Result.cands({ read_only(q, version, nil, 'eof') }) end
  return wait('stream:readable', q, { op = 'consume_some', need = 'bytes_or_eof' })
end

local function eval_consume_exactly(q, payload, ctx)
  local n = as_nonneg_int(payload.n, 0, 'stream exact read size')
  local v = ctx_view(ctx, q)
  local version = observe_version(ctx, q)
  if n == 0 then return Result.cands({ read_only(q, version, '') }) end
  if (v.length or 0) >= n then
    local bytes = peek_bytes(v, n)
    local c = Candidate.new(OpPack(bytes))
    add_op(c, q, { kind = 'consume', n = n }, version)
    return Result.cands({ c })
  end
  if (not v.writer_open) or v.read_error then
    local partial = buffer_to_string(v)
    local c = Candidate.new(OpPack(nil, v.read_error or 'eof', partial))
    if #partial > 0 then add_op(c, q, { kind = 'consume', n = #partial }, version) else ensure_record(c, q, version) end
    return Result.cands({ c })
  end
  return wait('stream:readable', q, { op = 'consume_exactly', need = n })
end

local function eval_consume_line(q, payload, ctx)
  local sep = validate_sep(payload.sep)
  local include_sep = payload.include_sep == true
  local limit = validate_limit(payload.limit)
  local v = ctx_view(ctx, q)
  local version = observe_version(ctx, q)
  local pos, prefix = find_sep_in_buffer(v, sep, limit)
  if pos then
    if limit and (pos - 1) > limit then return Result.cands({ read_only(q, version, nil, 'line_too_long') }) end
    local consume_n = pos + #sep - 1
    local out_n = include_sep and consume_n or (pos - 1)
    local line = string.sub(prefix, 1, out_n)
    local c = Candidate.new(OpPack(line))
    add_op(c, q, { kind = 'consume', n = consume_n }, version)
    return Result.cands({ c })
  end
  if limit and (v.length or 0) > limit then return Result.cands({ read_only(q, version, nil, 'line_too_long') }) end
  if (v.length or 0) > 0 and not v.writer_open then
    local tail = buffer_to_string(v)
    local c = Candidate.new(OpPack(tail))
    add_op(c, q, { kind = 'consume', n = #tail }, version)
    return Result.cands({ c })
  end
  if v.read_error then return Result.cands({ read_only(q, version, nil, v.read_error) }) end
  if not v.writer_open then return Result.cands({ read_only(q, version, nil, 'eof') }) end
  return wait('stream:readable', q, { op = 'consume_line', sep = sep })
end

local function eval_close(q, which, _payload, ctx)
  local v = ctx_view(ctx, q)
  local version = observe_version(ctx, q)
  if which == 'writer' and not v.writer_open then return Result.cands({ read_only(q, version, true) }) end
  if which == 'reader' and not v.reader_open then return Result.cands({ read_only(q, version, true) }) end
  local c = Candidate.new(OpPack(true))
  add_op(c, q, { kind = which == 'writer' and 'close_writer' or 'close_reader' }, version)
  return Result.cands({ c })
end

local function eval_empty(q, _payload, ctx)
  local v = ctx_view(ctx, q)
  local version = observe_version(ctx, q)
  if (v.length or 0) == 0 then return Result.cands({ read_only(q, version, true) }) end
  if v.write_error then return Result.cands({ read_only(q, version, nil, v.write_error) }) end
  return wait('stream:drained', q, { op = 'empty' })
end

function ByteQueueKind.eval(q, payload, ctx)
  local op = payload.op
  if op == 'append' then return eval_append(q, payload, ctx)
  elseif op == 'consume_some' then return eval_consume_some(q, payload, ctx)
  elseif op == 'consume_exactly' then return eval_consume_exactly(q, payload, ctx)
  elseif op == 'consume_line' then return eval_consume_line(q, payload, ctx)
  elseif op == 'close_writer' then return eval_close(q, 'writer', payload, ctx)
  elseif op == 'close_reader' then return eval_close(q, 'reader', payload, ctx)
  elseif op == 'empty' then return eval_empty(q, payload, ctx)
  elseif op == 'state' then
    local version = observe_version(ctx, q)
    local v = ctx_view(ctx, q)
    return Result.cands({ read_only(q, version, state_table(q, v)) })
  elseif op == 'changed' then
    local version = observe_version(ctx, q)
    local v = ctx_view(ctx, q)
    if version ~= payload.version then
      return Result.cands({ read_only(q, version, state_table(q, v)) })
    end
    return wait('stream:changed', q, { op = 'changed', version = payload.version })
  end
  error('unknown byte queue operation ' .. tostring(op), 2)
end

function ByteQueueKind.summary(payload, out)
  out.resources = true
  out.dynamic = true
  out.closed = false
  local op = payload and payload.op
  if op and string.sub(op, 1, 7) == 'consume' then out.reads = true end
  if op == 'append' then out.writes = true end
end

function ByteQueue.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'byte-queue-' .. tostring(next_id)
  local capacity = opts.capacity
  if capacity ~= nil then capacity = as_nonneg_int(capacity, nil, 'ByteQueue capacity') end
  local q = setmetatable({
    chunks = {},
    head_chunk = 1,
    head_offset = 1,
    length = 0,
    capacity = capacity,
    writer_open = opts.writer_open ~= false,
    reader_open = opts.reader_open ~= false,
    read_error = opts.read_error,
    write_error = opts.write_error,
    version = 0,
    name = opts.name or id,
    _fibers_id = id,
    _fibers_kind = ByteQueueKind,
  }, ByteQueue)
  if opts.data then append_chunk(q, as_bytes(opts.data)) end
  return q
end

function ByteQueue:append_op(bytes)
  bytes = as_bytes(bytes or '')
  return Op._resource(self, ByteQueueKind, { op = 'append', bytes = bytes, some = false })
end

function ByteQueue:append_some_op(bytes)
  bytes = as_bytes(bytes or '')
  return Op._resource(self, ByteQueueKind, { op = 'append', bytes = bytes, some = true })
end

function ByteQueue:consume_some_op(max)
  return Op._resource(self, ByteQueueKind, { op = 'consume_some', max = as_nonneg_int(max, 1, 'stream read size') })
end

function ByteQueue:consume_exactly_op(n)
  return Op._resource(self, ByteQueueKind, { op = 'consume_exactly', n = as_nonneg_int(n, 0, 'stream exact read size') })
end

function ByteQueue:consume_line_op(opts)
  opts = opts or {}
  return Op._resource(self, ByteQueueKind, {
    op = 'consume_line',
    sep = validate_sep(opts.sep or '\n'),
    include_sep = opts.include_sep == true,
    limit = validate_limit(opts.limit),
  })
end

function ByteQueue:close_writer_op(reason)
  return Op._resource(self, ByteQueueKind, { op = 'close_writer', reason = reason })
end

function ByteQueue:close_reader_op(reason)
  return Op._resource(self, ByteQueueKind, { op = 'close_reader', reason = reason })
end

function ByteQueue:empty_op()
  return Op._resource(self, ByteQueueKind, { op = 'empty' })
end

function ByteQueue:state_op()
  return Op._resource(self, ByteQueueKind, { op = 'state' })
end

function ByteQueue:debug_data()
  return buffer_to_string(view_from_queue(self))
end

function ByteQueue:changed_op(version)
  return Op._resource(self, ByteQueueKind, { op = 'changed', version = version })
end

ByteQueue.Kind = ByteQueueKind
return ByteQueue
