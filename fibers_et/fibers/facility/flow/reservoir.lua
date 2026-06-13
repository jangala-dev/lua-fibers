-- Transactional byte reservoir for Flow.
--
-- A reservoir is the byte-retention resource inside a Flow.  Retained bytes are
-- either queued (available to the Outlet) or leased (temporarily owned by a pump
-- or downstream actor).  Capacity is an invariant over all retained bytes:
--
--   retained = queued + leased
--   free     = limit - retained
--
-- Retained bytes may be settled when the committed state proves there is no
-- future consumer or deliverer for them. Settlement releases queued bytes and
-- active leases in the same transaction that records the terminal fact.
--
-- Queued bytes are stored as a Lua rope of immutable string chunks.  The current
-- implementation deliberately permits only one active lease per reservoir; this
-- preserves byte order while keeping the first lease algebra simple.

local Op = require('fibers.base.op')
local Candidate = require('fibers.kernel.algebra.candidate')
local Result = require('fibers.kernel.algebra.result')
local Wait = require('fibers.kernel.wait')
local Versioned = require('fibers.kernel.resources.versioned')
local Errors = require('fibers.facility.flow.errors')
local Rope = require('fibers.facility.flow.rope')
local Segment = require('fibers.facility.flow.segment')
local Lease = require('fibers.facility.flow.lease')

local OpPack = Op._pack
local Reservoir = {}
Reservoir.__index = Reservoir
local ReservoirKind = { name = 'flow_reservoir' }
local next_id = 0
local INF = 1/0

-- Validation ----------------------------------------------------------------

local function as_bytes(bytes)
  if Segment.is(bytes) then return Segment.bytes(bytes) end
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

local function as_pos_int(n, default, label)
  n = as_nonneg_int(n, default, label)
  if n <= 0 then error((label or 'Flow byte count') .. ' must be positive', 3) end
  return n
end

local function as_sep(sep)
  sep = sep or '\n'
  if type(sep) ~= 'string' or sep == '' then error('Flow line separator must be a non-empty string', 3) end
  return sep
end

local function as_limit(n, label)
  if n == nil then return nil end
  return as_nonneg_int(n, nil, label or 'Flow limit')
end

-- State projection -----------------------------------------------------------

local function copy_leases(src)
  local out = {}
  if src then
    for id, l in pairs(src) do out[id] = { id = l.id, bytes = l.bytes or '', owner = l.owner, meta = l.meta } end
  end
  return out
end

local function leased_length(leases)
  local n = 0
  for _, l in pairs(leases or {}) do n = n + #(l.bytes or '') end
  return n
end

local function lease_count(leases)
  local n = 0
  for _ in pairs(leases or {}) do n = n + 1 end
  return n
end

local function first_lease_for(st, owner)
  for id, l in pairs(st.leases or {}) do
    if owner == nil or l.owner == owner then return id, l end
  end
  return nil
end

local function queued_length(st) return st.rope:length() end
local function queued_data(st) return st.rope:tostring() end
local function retained_length(st) return queued_length(st) + leased_length(st.leases) end
local function free_bytes(st)
  if st.limit == nil then return INF end
  local f = st.limit - retained_length(st)
  return f < 0 and 0 or f
end

local function inspect(res, st)
  local leases = copy_leases(st.leases)
  local qlen = queued_length(st)
  local data = st.rope:tostring()
  local chunks = st.rope:chunk_count()
  return {
    reservoir = res,
    length = qlen,
    queued_length = qlen,
    leased_length = leased_length(st.leases),
    retained_length = retained_length(st),
    data = data,
    segment_count = chunks,
    chunk_count = chunks,
    capacity = st.limit,
    limit = st.limit,
    free = free_bytes(st),
    leases = leases,
    lease_count = lease_count(st.leases),
    version = st.version or 0,
  }
end

local function base_state(res)
  return {
    rope = res.rope and res.rope:clone() or Rope.new(res.data or ''),
    leases = copy_leases(res.leases),
    limit = res.limit,
    version = res.version or 0,
    next_lease = res.next_lease or 0,
  }
end

local function apply_op(st, op)
  if op.kind == 'append' then
    st.rope:append(op.bytes or '')
  elseif op.kind == 'consume' then
    st.rope:take(math.min(op.n or 0, st.rope:length()))
  elseif op.kind == 'lease' then
    local n = math.min(op.n or 0, st.rope:length())
    local bytes = st.rope:take(n)
    st.leases[op.id] = { id = op.id, bytes = bytes, owner = op.owner, meta = op.meta }
    st.next_lease = math.max(st.next_lease or 0, op.seq or 0)
  elseif op.kind == 'ack' then
    local l = st.leases[op.id]
    if l then
      local n = math.min(op.n or 0, #(l.bytes or ''))
      l.bytes = string.sub(l.bytes or '', n + 1)
      if l.bytes == '' then st.leases[op.id] = nil end
    end
  elseif op.kind == 'return' then
    local l = st.leases[op.id]
    if l then
      st.rope:prepend(l.bytes or '')
      st.leases[op.id] = nil
    end
  elseif op.kind == 'drop_lease' then
    st.leases[op.id] = nil
  elseif op.kind == 'settle' then
    st.rope = Rope.new('')
    st.leases = {}
  end
end

local function project(res, rec)
  local st = base_state(res)
  for i = 1, #(rec and rec.ops or {}) do apply_op(st, rec.ops[i]) end
  return st
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

local function mutating(ops) return #(ops or {}) > 0 end

-- Candidate helpers ---------------------------------------------------------

local function ensure(c, res, version)
  local rec = Versioned.ensure(c, res, ReservoirKind, version)
  rec.ops = rec.ops or {}
  return rec
end

local function note(c, res, version, op)
  local rec = ensure(c, res, version)
  rec.ops[#rec.ops + 1] = op
  return c
end

local function ro(res, version, ...)
  return Result.cands({ Versioned.read_only(res, ReservoirKind, version, OpPack, ...) })
end

local function wait(res, detail)
  return Result.wait(Wait.resource('flow:reservoir:changed', res._fibers_id, res, detail))
end

local function wake_set(res)
  return Versioned.wake_set('flow:reservoir:changed', res._fibers_id, { reservoir = res })
end

local function commit_consume(res, version, st, n)
  local bytes = st.rope:peek(n)
  local c = Candidate.new(OpPack(bytes))
  note(c, res, version, { kind = 'consume', n = n })
  return Result.cands({ c })
end

local function commit_append(res, version, bytes)
  bytes = as_bytes(bytes)
  if bytes == '' then return ro(res, version, 0) end
  local c = Candidate.new(OpPack(#bytes))
  note(c, res, version, { kind = 'append', bytes = bytes })
  return Result.cands({ c })
end

local function line_fact(st, sep, limit, include_sep)
  local data = st.rope:tostring()
  local pos = string.find(data, sep, 1, true)
  local prefix_len = pos and (pos - 1) or #data
  if limit ~= nil and prefix_len > limit then return nil, Errors.LINE_TOO_LONG end
  if not pos then return nil, nil, false end
  local consume_n = pos + #sep - 1
  return { consume_n = consume_n, value_n = include_sep and consume_n or pos - 1 }, nil, true
end

local function lease_handle(res, id, l)
  return Lease.new(res, id, l.owner, l.bytes or '', { meta = l.meta })
end

-- Resource kind -------------------------------------------------------------

function ReservoirKind.clone(rec)
  return { kind = ReservoirKind, read = rec.read, ops = clone_ops(rec.ops) }
end

function ReservoirKind.merge_seq(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  dst.ops = dst.ops or {}
  for i = 1, #(src.ops or {}) do dst.ops[#dst.ops + 1] = src.ops[i] end
  return true
end

function ReservoirKind.merge_par(dst, src)
  if src.read ~= nil and dst.read == nil then dst.read = src.read end
  local a, b = mutating(dst.ops), mutating(src.ops)
  if a and b then return false, Errors.RESERVOIR_PARALLEL_CONFLICT end
  if b then
    dst.ops = dst.ops or {}
    for i = 1, #(src.ops or {}) do dst.ops[#dst.ops + 1] = src.ops[i] end
  end
  return true
end

function ReservoirKind.project(res, rec, query)
  local st = project(res, rec)
  if query == 'inspect' or query == 'snapshot' then return inspect(res, st), true end
  if query == 'data' then return queued_data(st), true end
  if query == 'length' or query == 'queued_length' then return queued_length(st), true end
  if query == 'leased_length' then return leased_length(st.leases), true end
  if query == 'retained_length' then return retained_length(st), true end
  if query == 'free' then return free_bytes(st), true end
  if query == 'empty' then return queued_length(st) == 0 and leased_length(st.leases) == 0, true end
  if query == 'queued_empty' then return queued_length(st) == 0, true end
  if query == 'leases_empty' then return leased_length(st.leases) == 0, true end
  return nil, false
end

function ReservoirKind.prepare(res, rec, _resolve)
  if rec.read ~= nil and (res.version or 0) ~= rec.read then return nil, 'stale' end
  if not mutating(rec.ops) then return nil, nil, true end
  local st = base_state(res)
  for i = 1, #(rec.ops or {}) do
    local op = rec.ops[i]
    if op.kind == 'append' and res.limit ~= nil and free_bytes(st) < #(op.bytes or '') then return nil, Errors.CAPACITY end
    if op.kind == 'lease' then
      if lease_count(st.leases) > 0 then return nil, Errors.LEASE_ALREADY_ACTIVE end
      if queued_length(st) < (op.n or 0) then return nil, Errors.UNDERFLOW end
    end
    if op.kind == 'consume' and queued_length(st) < (op.n or 0) then return nil, Errors.UNDERFLOW end
    if op.kind == 'ack' then
      local l = st.leases[op.id]
      if not l then return nil, Errors.NO_LEASE end
      if op.owner ~= nil and l.owner ~= op.owner then return nil, Errors.LEASE_OWNER_MISMATCH end
      if (op.n or 0) > #(l.bytes or '') then return nil, Errors.LEASE_ACK_TOO_LARGE end
    end
    if (op.kind == 'return' or op.kind == 'drop_lease') and not st.leases[op.id] then return nil, Errors.NO_LEASE end
    apply_op(st, op)
  end
  local set, err = wake_set(res)
  if err then return nil, err end
  return { kind = ReservoirKind, resource = res, ops = clone_ops(rec.ops), consequence_set = set }
end

function ReservoirKind.apply(prepared, _log)
  local res = prepared.resource
  local st = base_state(res)
  for i = 1, #(prepared.ops or {}) do apply_op(st, prepared.ops[i]) end
  res.rope = st.rope
  res.data = nil
  res.leases = copy_leases(st.leases)
  res.next_lease = st.next_lease or res.next_lease or 0
  res.version = (res.version or 0) + 1
end

function ReservoirKind.eval(res, payload, ctx)
  local op = payload.op
  local version = Versioned.observe(ctx, res)
  local rec = Versioned.overlay_rec(ctx, res)
  local st = project(res, rec)

  if op == 'inspect' then return ro(res, version, inspect(res, st))
  elseif op == 'append' then
    local bytes = as_bytes(payload.bytes or '')
    if res.limit ~= nil and #bytes > res.limit then return ro(res, version, nil, Errors.TOO_LARGE) end
    if free_bytes(st) < #bytes then return wait(res, { op = 'append', n = #bytes }) end
    return commit_append(res, version, bytes)
  elseif op == 'append_some' then
    local bytes = as_bytes(payload.bytes or '')
    local n = math.min(#bytes, free_bytes(st))
    if n <= 0 and #bytes > 0 then return wait(res, { op = 'append_some', n = #bytes }) end
    return commit_append(res, version, string.sub(bytes, 1, n))
  elseif op == 'free_some' then
    local n = math.min(payload.max or 1, free_bytes(st))
    if n > 0 then return ro(res, version, n) end
    return wait(res, { op = 'free_some', max = payload.max })
  elseif op == 'consume' then
    local n = as_nonneg_int(payload.n, 0, 'Flow consume size')
    if queued_length(st) < n then return wait(res, { op = 'consume', n = n }) end
    return commit_consume(res, version, st, n)
  elseif op == 'consume_some' then
    local max = as_pos_int(payload.max, 4096, 'Flow consume_some size')
    local n = math.min(max, queued_length(st))
    if n <= 0 then return wait(res, { op = 'consume_some', max = max }) end
    return commit_consume(res, version, st, n)
  elseif op == 'consume_exactly' then
    local n = as_nonneg_int(payload.n, 0, 'Flow exact consume size')
    if n == 0 then return ro(res, version, '') end
    if queued_length(st) < n then return wait(res, { op = 'consume_exactly', n = n }) end
    return commit_consume(res, version, st, n)
  elseif op == 'consume_short' then
    local n = as_nonneg_int(payload.n, 0, 'Flow short consume size')
    local available = queued_length(st)
    if available >= n then return wait(res, { op = 'consume_short', n = n }) end
    return commit_consume(res, version, st, available)
  elseif op == 'consume_available_within' then
    local max = as_limit(payload.max, 'Flow consume_available limit')
    local available = queued_length(st)
    if max ~= nil and available > max then return ro(res, version, nil, Errors.TOO_LARGE) end
    return commit_consume(res, version, st, available)
  elseif op == 'find_line' then
    local sep = as_sep(payload.sep)
    local fact, err, hit = line_fact(st, sep, as_limit(payload.limit, 'Flow line limit'), payload.include_sep == true)
    if err then return ro(res, version, nil, err) end
    if hit then return ro(res, version, fact) end
    return wait(res, { op = 'find_line', sep = sep, limit = payload.limit })
  elseif op == 'consume_unmatched_line' then
    local sep = as_sep(payload.sep)
    local fact, err, hit = line_fact(st, sep, as_limit(payload.limit, 'Flow line limit'), payload.include_sep == true)
    if err then return ro(res, version, nil, err) end
    if hit then return wait(res, { op = 'consume_unmatched_line', sep = sep }) end
    return commit_consume(res, version, st, queued_length(st))
  elseif op == 'too_large' then
    local max = as_limit(payload.max, 'Flow too_large limit')
    if max ~= nil and queued_length(st) > max then return ro(res, version, true) end
    return wait(res, { op = 'too_large', max = max })
  elseif op == 'empty' then
    if queued_length(st) == 0 and leased_length(st.leases) == 0 then return ro(res, version, true) end
    return wait(res, { op = 'empty' })
  elseif op == 'queued_empty' then
    if queued_length(st) == 0 then return ro(res, version, true) end
    return wait(res, { op = 'queued_empty' })
  elseif op == 'leases_empty' then
    if leased_length(st.leases) == 0 then return ro(res, version, true) end
    return wait(res, { op = 'leases_empty' })
  elseif op == 'settle' then
    if queued_length(st) == 0 and leased_length(st.leases) == 0 then return ro(res, version, true) end
    local c = Candidate.new(OpPack(true, inspect(res, st)))
    note(c, res, version, { kind = 'settle', reason = payload.reason })
    return Result.cands({ c })
  elseif op == 'lease_some' then
    local owner = payload.owner
    local existing_id, existing = first_lease_for(st, owner)
    if existing then return ro(res, version, lease_handle(res, existing_id, existing)) end
    if lease_count(st.leases) > 0 then return ro(res, version, nil, Errors.LEASE_ALREADY_ACTIVE) end
    local max = as_pos_int(payload.max, 4096, 'Flow lease size')
    local n = math.min(max, queued_length(st))
    if n <= 0 then return wait(res, { op = 'lease_some', max = max }) end
    local seq = (res.next_lease or 0) + 1
    local id = tostring(res._fibers_id) .. ':lease:' .. tostring(seq)
    local bytes = st.rope:peek(n)
    local lease = Lease.new(res, id, owner, bytes)
    local c = Candidate.new(OpPack(lease))
    note(c, res, version, { kind = 'lease', id = id, seq = seq, n = n, owner = owner })
    return Result.cands({ c })
  elseif op == 'lease_existing' then
    local id, l = first_lease_for(st, payload.owner)
    if l then return ro(res, version, lease_handle(res, id, l)) end
    return ro(res, version, nil, Errors.NO_LEASE)
  elseif op == 'ack_lease' then
    local id = payload.id
    local l = st.leases[id]
    if not l then return ro(res, version, nil, Errors.NO_LEASE) end
    if payload.owner ~= nil and l.owner ~= payload.owner then return ro(res, version, nil, Errors.LEASE_OWNER_MISMATCH) end
    local n = as_nonneg_int(payload.n, 0, 'Flow lease acknowledgement')
    if n > #(l.bytes or '') then return ro(res, version, nil, Errors.LEASE_ACK_TOO_LARGE) end
    local remaining = string.sub(l.bytes or '', n + 1)
    local c = Candidate.new(OpPack(true, n, remaining))
    note(c, res, version, { kind = 'ack', id = id, n = n, owner = payload.owner })
    return Result.cands({ c })
  elseif op == 'return_lease' then
    local id = payload.id
    if not st.leases[id] then return ro(res, version, nil, Errors.NO_LEASE) end
    local c = Candidate.new(OpPack(true))
    note(c, res, version, { kind = 'return', id = id })
    return Result.cands({ c })
  elseif op == 'fail_lease' then
    local id = payload.id
    if not st.leases[id] then return ro(res, version, nil, Errors.NO_LEASE) end
    local c = Candidate.new(OpPack(true))
    note(c, res, version, { kind = 'drop_lease', id = id, error = payload.error })
    return Result.cands({ c })
  elseif op == 'changed' then
    if version ~= payload.version then return ro(res, version, inspect(res, st)) end
    return wait(res, { op = 'changed', version = payload.version })
  end

  error(Errors.RESERVOIR_UNKNOWN_OP .. ':' .. tostring(op), 2)
end

function ReservoirKind.summary(_payload, out) out.resources = true; out.dynamic = true; out.closed = false end

-- Public methods ------------------------------------------------------------

function Reservoir.new(opts)
  opts = opts or {}
  local limit = opts.limit or opts.capacity
  if limit ~= nil then limit = as_nonneg_int(limit, nil, 'Flow capacity') end
  next_id = next_id + 1
  local id = 'flow-reservoir-' .. tostring(next_id)
  return setmetatable({
    rope = Rope.new(opts.data or ''),
    leases = {},
    limit = limit,
    next_lease = 0,
    version = 0,
    name = opts.name or id,
    _fibers_id = id,
    _fibers_kind = ReservoirKind,
  }, Reservoir)
end

function Reservoir:append_op(bytes) return Op._resource(self, ReservoirKind, { op = 'append', bytes = as_bytes(bytes or '') }) end
function Reservoir:append_some_op(bytes) return Op._resource(self, ReservoirKind, { op = 'append_some', bytes = as_bytes(bytes or '') }) end
function Reservoir:consume_op(n) return Op._resource(self, ReservoirKind, { op = 'consume', n = as_nonneg_int(n, 0, 'Flow consume size') }) end
function Reservoir:consume_some_op(max) return Op._resource(self, ReservoirKind, { op = 'consume_some', max = as_pos_int(max, 4096, 'Flow consume_some size') }) end
function Reservoir:consume_exactly_op(n) return Op._resource(self, ReservoirKind, { op = 'consume_exactly', n = as_nonneg_int(n, 0, 'Flow exact consume size') }) end
function Reservoir:consume_short_op(n) return Op._resource(self, ReservoirKind, { op = 'consume_short', n = as_nonneg_int(n, 0, 'Flow short consume size') }) end
function Reservoir:consume_available_within_op(max) return Op._resource(self, ReservoirKind, { op = 'consume_available_within', max = as_limit(max, 'Flow consume_available limit') }) end
function Reservoir:find_line_op(spec) spec = spec or {}; return Op._resource(self, ReservoirKind, { op = 'find_line', sep = spec.sep or '\n', include_sep = spec.include_sep == true, limit = spec.limit }) end
function Reservoir:consume_unmatched_line_op(spec) spec = spec or {}; return Op._resource(self, ReservoirKind, { op = 'consume_unmatched_line', sep = spec.sep or '\n', include_sep = spec.include_sep == true, limit = spec.limit }) end
function Reservoir:too_large_op(max) return Op._resource(self, ReservoirKind, { op = 'too_large', max = as_limit(max, 'Flow too_large limit') }) end
function Reservoir:empty_op() return Op._resource(self, ReservoirKind, { op = 'empty' }) end
function Reservoir:queued_empty_op() return Op._resource(self, ReservoirKind, { op = 'queued_empty' }) end
function Reservoir:leases_empty_op() return Op._resource(self, ReservoirKind, { op = 'leases_empty' }) end
function Reservoir:settle_op(reason) return Op._resource(self, ReservoirKind, { op = 'settle', reason = reason }) end
function Reservoir:free_some_op(max) return Op._resource(self, ReservoirKind, { op = 'free_some', max = as_pos_int(max, 1, 'Flow free_some size') }) end
function Reservoir:lease_some_op(owner, max) return Op._resource(self, ReservoirKind, { op = 'lease_some', owner = owner, max = as_pos_int(max, 4096, 'Flow lease size') }) end
function Reservoir:lease_existing_op(owner) return Op._resource(self, ReservoirKind, { op = 'lease_existing', owner = owner }) end
function Reservoir:ack_lease_op(lease, n)
  local id = type(lease) == 'table' and lease.id or lease
  local owner = type(lease) == 'table' and lease.owner or nil
  if type(id) ~= 'string' then error('Flow lease acknowledgement expects a lease or id', 2) end
  return Op._resource(self, ReservoirKind, { op = 'ack_lease', id = id, owner = owner, n = as_nonneg_int(n, 0, 'Flow lease acknowledgement') })
end
function Reservoir:return_lease_op(lease)
  local id = type(lease) == 'table' and lease.id or lease
  if type(id) ~= 'string' then error('Flow lease return expects a lease or id', 2) end
  return Op._resource(self, ReservoirKind, { op = 'return_lease', id = id })
end
function Reservoir:fail_lease_op(lease, err)
  local id = type(lease) == 'table' and lease.id or lease
  if type(id) ~= 'string' then error('Flow lease failure expects a lease or id', 2) end
  return Op._resource(self, ReservoirKind, { op = 'fail_lease', id = id, error = err })
end
function Reservoir:inspect_op() return Op._resource(self, ReservoirKind, { op = 'inspect' }) end
function Reservoir:changed_op(version) return Op._resource(self, ReservoirKind, { op = 'changed', version = version }) end
function Reservoir:debug_data() return self.rope and self.rope:tostring() or '' end
function Reservoir:debug_leased_bytes() local n=0; for _,l in pairs(self.leases or {}) do n=n+#(l.bytes or '') end; return n end
function Reservoir:debug_first_lease_bytes() for _,l in pairs(self.leases or {}) do return l.bytes or '' end; return nil end

Reservoir.Kind = ReservoirKind
return Reservoir
