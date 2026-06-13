-- Transactional byte storage for Flow.
--
-- Buffer is deliberately small: it owns committed bytes and byte journals.
-- It does not know about EOF, broken pipes, pumps, readiness, stream shutdown,
-- or settlement.  Flow composes these byte facts with half-state and capacity.
--
-- Laws:
--   * observing bytes is read-only;
--   * appending and consuming are journals;
--   * losing journals leave storage unchanged;
--   * parallel byte mutations of the same buffer conflict unless sequenced.

local Op = require('fibers.base.op')
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

-- Validation ---------------------------------------------------------------

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then error('Flow bytes must be a string', 3) end
  return bytes
end

local function as_count(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'Flow byte count') .. ' must be a non-negative integer', 3)
  end
  return n
end

local function as_sep(sep)
  sep = sep or '\n'
  if type(sep) ~= 'string' or sep == '' then error('Flow line separator must be a non-empty string', 3) end
  return sep
end

local function as_limit(n, label)
  if n == nil then return nil end
  return as_count(n, nil, label)
end

-- Byte views ---------------------------------------------------------------

local function compact(buf)
  local first = buf.head_chunk or 1
  if first <= COMPACT_AFTER then return end
  local src, dst = buf.chunks or {}, {}
  for i = first, #src do dst[#dst + 1] = src[i] end
  buf.chunks, buf.head_chunk = dst, 1
end

local function append_to(buf, bytes)
  if bytes == '' then return end
  local chunks = buf.chunks
  local last = chunks[#chunks]
  if last and #last + #bytes <= COALESCE_LIMIT then chunks[#chunks] = last .. bytes
  else chunks[#chunks + 1] = bytes end
  buf.length = (buf.length or 0) + #bytes
end

local function peek(buf, n)
  n = math.min(n or buf.length or 0, buf.length or 0)
  if n <= 0 then return '' end

  local out, remaining = {}, n
  local chunks = buf.chunks or {}
  local idx, off = buf.head_chunk or 1, buf.head_offset or 1
  while remaining > 0 do
    local chunk = chunks[idx]
    if not chunk then break end
    local avail = #chunk - off + 1
    if avail > 0 then
      local take = math.min(avail, remaining)
      out[#out + 1] = string.sub(chunk, off, off + take - 1)
      remaining = remaining - take
    end
    idx, off = idx + 1, 1
  end
  return table.concat(out)
end

local function consume_from(buf, n)
  n = math.min(n or 0, buf.length or 0)
  if n <= 0 then return '' end

  local bytes, remaining = peek(buf, n), n
  local chunks = buf.chunks
  while remaining > 0 do
    local idx = buf.head_chunk or 1
    local chunk = chunks[idx]
    if not chunk then break end
    local off = buf.head_offset or 1
    local avail = #chunk - off + 1
    local take = math.min(avail, remaining)
    remaining = remaining - take
    if take == avail then buf.head_chunk, buf.head_offset = idx + 1, 1
    else buf.head_offset = off + take end
  end

  buf.length = (buf.length or 0) - n
  if buf.length <= 0 then
    buf.length, buf.chunks, buf.head_chunk, buf.head_offset = 0, {}, 1, 1
  else
    compact(buf)
  end
  return bytes
end

local function view_of(buffer)
  local chunks, src = {}, buffer.chunks or {}
  for i = buffer.head_chunk or 1, #src do chunks[#chunks + 1] = src[i] end
  return {
    chunks = chunks,
    head_chunk = 1,
    head_offset = buffer.head_offset or 1,
    length = buffer.length or 0,
    version = buffer.version or 0,
  }
end

local function apply_op(view, op)
  if op.kind == 'append' then append_to(view, op.bytes or '')
  elseif op.kind == 'consume' then consume_from(view, op.n or 0) end
end

local function project(buffer, rec)
  local v = view_of(buffer)
  for i = 1, #(rec and rec.ops or {}) do apply_op(v, rec.ops[i]) end
  return v
end

local function inspect(buffer, view)
  return {
    buffer = buffer,
    length = view.length or 0,
    data = peek(view, view.length or 0),
    chunk_count = #(view.chunks or {}),
    version = view.version or 0,
  }
end

local function line_fact(view, sep, limit, include_sep)
  local data = peek(view, view.length or 0)
  local pos = string.find(data, sep, 1, true)
  local prefix_len = pos and (pos - 1) or (view.length or 0)
  if limit ~= nil and prefix_len > limit then return nil, Errors.LINE_TOO_LONG end
  if not pos then return nil, nil, false end
  local consume_n = pos + #sep - 1
  return { consume_n = consume_n, value_n = include_sep and consume_n or pos - 1 }, nil, true
end

-- Candidate helpers --------------------------------------------------------

local function ensure(c, buffer, version)
  local rec = Versioned.ensure(c, buffer, BufferKind, version)
  rec.ops = rec.ops or {}
  return rec
end

local function note(c, buffer, version, op)
  local rec = ensure(c, buffer, version)
  rec.ops[#rec.ops + 1] = op
  return c
end

local function ro(buffer, version, ...)
  return Result.cands({ Versioned.read_only(buffer, BufferKind, version, OpPack, ...) })
end

local function wait(buffer, detail)
  return Result.wait(Wait.resource('flow:buffer:changed', buffer._fibers_id, buffer, detail))
end

local function commit_consume(buffer, version, view, n)
  local c = Candidate.new(OpPack(peek(view, n)))
  note(c, buffer, version, { kind = 'consume', n = n })
  return Result.cands({ c })
end

local function commit_append(buffer, version, bytes)
  if bytes == '' then return ro(buffer, version, 0) end
  local c = Candidate.new(OpPack(#bytes))
  note(c, buffer, version, { kind = 'append', bytes = bytes })
  return Result.cands({ c })
end

local function consume_when(decide)
  return function(buffer, payload, view, version)
    local n, wait_detail = decide(view, payload)
    if n == nil then return wait(buffer, wait_detail or payload) end
    return commit_consume(buffer, version, view, n)
  end
end

local function fact_when(test)
  return function(buffer, payload, view, version)
    local ok, value, wait_detail = test(view, payload)
    if ok then return ro(buffer, version, value == nil and true or value) end
    return wait(buffer, wait_detail or payload)
  end
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

local function wake_set(buffer)
  return Versioned.wake_set('flow:buffer:changed', buffer._fibers_id, { buffer = buffer })
end

-- Resource kind ------------------------------------------------------------

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
  local v = project(buffer, rec)
  if query == 'inspect' or query == 'snapshot' then return inspect(buffer, v), true end
  if query == 'length' then return v.length or 0, true end
  if query == 'data' then return peek(v, v.length or 0), true end
  return nil, false
end

function BufferKind.prepare(buffer, rec, resolve)
  if rec.read ~= nil and (buffer.version or 0) ~= rec.read then return nil, 'stale' end
  local ops = rec.ops or {}
  if #ops == 0 then return nil, nil, true end

  local v, prepared = view_of(buffer), {}
  for i = 1, #ops do
    local op = {}; for k, val in pairs(ops[i]) do op[k] = val end
    if op.bytes ~= nil then op.bytes = resolve(op.bytes) end
    if op.kind ~= 'append' and op.kind ~= 'consume' then return nil, Errors.BUFFER_UNKNOWN_OP end
    if op.kind == 'consume' and (op.n or 0) > (v.length or 0) then return nil, Errors.UNDERFLOW end
    prepared[#prepared + 1] = op
    apply_op(v, op)
  end

  local set, err = wake_set(buffer)
  if err then return nil, err end
  return { kind = BufferKind, resource = buffer, ops = prepared, consequence_set = set }
end

function BufferKind.apply(prepared, _log)
  local b = prepared.resource
  local v = { chunks = b.chunks or {}, head_chunk = b.head_chunk or 1, head_offset = b.head_offset or 1, length = b.length or 0 }
  for i = 1, #(prepared.ops or {}) do apply_op(v, prepared.ops[i]) end
  b.chunks, b.head_chunk, b.head_offset, b.length = v.chunks, v.head_chunk, v.head_offset, v.length
  b.version = (b.version or 0) + 1
end

local EVAL = {}

function EVAL.append(buffer, payload, _view, version)
  return commit_append(buffer, version, as_bytes(payload.bytes or ''))
end

function EVAL.consume(buffer, payload, view, version)
  local n = as_count(payload.n, 0, 'Flow consume size')
  if n > (view.length or 0) then return ro(buffer, version, nil, Errors.UNDERFLOW) end
  return commit_consume(buffer, version, view, n)
end

EVAL.consume_some = consume_when(function(view, payload)
  local max = as_count(payload.max, 1, 'Flow consume_some size')
  if max == 0 then return 0 end
  if (view.length or 0) <= 0 then return nil, { op = 'consume_some', max = max } end
  return math.min(view.length or 0, max)
end)

EVAL.consume_exactly = consume_when(function(view, payload)
  local n = as_count(payload.n, 0, 'Flow consume_exactly size')
  if n == 0 then return 0 end
  if (view.length or 0) < n then return nil, { op = 'consume_exactly', n = n } end
  return n
end)

EVAL.consume_short = consume_when(function(view, payload)
  local n = as_count(payload.n, 0, 'Flow consume_short size')
  if (view.length or 0) >= n then return nil, { op = 'consume_short', n = n } end
  return view.length or 0
end)

EVAL.consume_available = consume_when(function(view, payload)
  local max = as_limit(payload.max, 'Flow consume_available size')
  local len = view.length or 0
  return math.min(len, max or len)
end)

EVAL.consume_available_within = consume_when(function(view, payload)
  local max = as_limit(payload.max, 'Flow consume_available_within size')
  local len = view.length or 0
  if max ~= nil and len > max then return nil, { op = 'consume_available_within', max = max } end
  return len
end)

function EVAL.find_line(buffer, payload, view, version)
  local sep = as_sep(payload.sep)
  local limit = as_limit(payload.limit, 'Flow line limit')
  local fact, err, ready = line_fact(view, sep, limit, payload.include_sep == true)
  if err then return ro(buffer, version, nil, err) end
  if ready then return ro(buffer, version, fact) end
  return wait(buffer, { op = 'find_line', sep = sep, limit = limit })
end

EVAL.consume_unmatched_line = consume_when(function(view, payload)
  local sep = as_sep(payload.sep)
  local limit = as_limit(payload.limit, 'Flow line limit')
  local _fact, err, ready = line_fact(view, sep, limit, payload.include_sep == true)
  if err or ready then return nil, { op = 'consume_unmatched_line', sep = sep, limit = limit } end
  return view.length or 0
end)

EVAL.too_large = fact_when(function(view, payload)
  local max = as_limit(payload.max, 'Flow buffer max')
  if max == nil then return false, nil, { op = 'too_large' } end
  return (view.length or 0) > max, true, { op = 'too_large', max = max }
end)

EVAL.empty = fact_when(function(view)
  return (view.length or 0) == 0, true, { op = 'empty' }
end)

function EVAL.inspect(buffer, _payload, view, version)
  return ro(buffer, version, inspect(buffer, view))
end

function BufferKind.eval(buffer, payload, ctx)
  local handler = EVAL[payload.op]
  if not handler then error('unknown Flow buffer operation ' .. tostring(payload.op), 2) end
  local version = Versioned.observe(ctx, buffer)
  local view = project(buffer, Versioned.overlay_rec(ctx, buffer))
  return handler(buffer, payload, view, version)
end

function BufferKind.summary(_payload, out)
  out.resources = true; out.dynamic = true; out.closed = false
end

-- Public Buffer ------------------------------------------------------------

function Buffer.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local id = 'flow-buffer-' .. tostring(next_id)
  local b = setmetatable({
    chunks = {}, head_chunk = 1, head_offset = 1, length = 0, version = 0,
    name = opts.name or id, _fibers_id = id, _fibers_kind = BufferKind,
  }, Buffer)
  if opts.data then append_to(b, as_bytes(opts.data)) end
  return b
end

local function resource_op(buffer, op, payload)
  payload = payload or {}; payload.op = op
  return Op._resource(buffer, BufferKind, payload)
end

function Buffer:append_op(bytes) return resource_op(self, 'append', { bytes = as_bytes(bytes or '') }) end
function Buffer:consume_op(n) return resource_op(self, 'consume', { n = as_count(n, 0, 'Flow consume size') }) end
function Buffer:consume_some_op(max) return resource_op(self, 'consume_some', { max = as_count(max, 1, 'Flow consume_some size') }) end
function Buffer:consume_exactly_op(n) return resource_op(self, 'consume_exactly', { n = as_count(n, 0, 'Flow consume_exactly size') }) end
function Buffer:consume_short_op(n) return resource_op(self, 'consume_short', { n = as_count(n, 0, 'Flow consume_short size') }) end
function Buffer:consume_available_op(max) return resource_op(self, 'consume_available', { max = as_limit(max, 'Flow consume_available size') }) end
function Buffer:consume_available_within_op(max) return resource_op(self, 'consume_available_within', { max = as_limit(max, 'Flow consume_available_within size') }) end
function Buffer:find_line_op(opts) opts = opts or {}; return resource_op(self, 'find_line', { sep = as_sep(opts.sep), include_sep = opts.include_sep == true, limit = as_limit(opts.limit, 'Flow line limit') }) end
function Buffer:consume_unmatched_line_op(opts) opts = opts or {}; return resource_op(self, 'consume_unmatched_line', { sep = as_sep(opts.sep), include_sep = opts.include_sep == true, limit = as_limit(opts.limit, 'Flow line limit') }) end
function Buffer:too_large_op(max) return resource_op(self, 'too_large', { max = as_limit(max, 'Flow buffer max') }) end
function Buffer:inspect_op() return resource_op(self, 'inspect') end
function Buffer:empty_op() return resource_op(self, 'empty') end
function Buffer:debug_data() return peek(view_of(self), self.length or 0) end

Buffer.Kind = BufferKind
return Buffer
