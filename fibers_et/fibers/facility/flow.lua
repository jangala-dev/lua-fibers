-- Transactional unidirectional byte flows.
--
-- A Flow is the primitive byte facility:
--
--   Inlet  ->  Flow  ->  Outlet
--
-- Flow itself is protocol composition.  The facts live in smaller resources:
--
--   Buffer          committed bytes
--   Producer Half   whether more bytes may be written
--   Consumer Half   whether bytes may still be read/drained
--   Capacity        byte admission credit
--   Claim           optional pump-only in-flight host write state
--
-- The central rule is: Buffer stores bytes; Flow decides what bytes mean at
-- protocol boundaries such as EOF, broken pipe, flush, and host-pump claims.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Ownership = require('fibers.internal.ownership')
local Buffer = require('fibers.facility.flow.buffer')
local Half = require('fibers.facility.flow.half')
local Capacity = require('fibers.facility.flow.capacity')
local Errors = require('fibers.facility.flow.errors')

local FlowFacility = {}
local Flow = {}; Flow.__index = Flow
local Inlet = {}; Inlet.__index = Inlet
local Outlet = {}; Outlet.__index = Outlet

local next_flow = 0
local DEFAULT_LINE_LIMIT = 64 * 1024

-- Validation and ownership --------------------------------------------------

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then error('Flow bytes must be a string', 3) end
  return bytes
end

local function as_count(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'Flow count') .. ' must be a non-negative integer', 3)
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
  return as_count(n, nil, label or 'Flow limit')
end

local function line_limit(opts)
  opts = opts or {}
  if opts.unlimited == true then return nil end
  return opts.limit == nil and DEFAULT_LINE_LIMIT or as_limit(opts.limit, 'Flow line limit')
end

local function read_all_max(opts)
  opts = opts or {}
  if opts.unlimited == true then return nil end
  if opts.max == nil then error('read_all_op expects opts.max or opts.unlimited = true', 3) end
  return as_limit(opts.max, 'Flow read_all max')
end

local function region_of(x) return x and x._fibers_lifetime and x:raw_region() or x end

local function expect_region(x, label)
  if not x or x._fibers_kind ~= Region.Kind then error(label .. ' expects a Region or Lifetime', 3) end
  return x
end

local function transfer_item_op(item, from, to, label)
  local from_region = expect_region(region_of(from), label)
  local to_region = expect_region(region_of(to), label)
  return from_region:reassign_op(item, to_region)
end

local function handle(mt, name, kind, fields)
  fields = fields or {}
  fields.kind = kind
  fields._fibers_kind_name = kind
  fields._fibers_obligation_kind = kind
  return setmetatable(Ownership.handle(name, fields), mt)
end

local function make_inlet(flow, name)
  return handle(Inlet, name, 'flow_inlet', { flow = flow, _fibers_flow_inlet = true })
end

local function make_outlet(flow, name)
  return handle(Outlet, name, 'flow_outlet', { flow = flow, _fibers_flow_outlet = true })
end

-- Flow construction and inspection -----------------------------------------

function Flow.new(opts)
  opts = opts or {}
  next_flow = next_flow + 1
  local name = opts.name or ('flow-' .. tostring(next_flow))
  local f = handle(Flow, name, 'flow', {
    buffer = opts.buffer or Buffer.new { name = name .. ':buffer' },
    producer = opts.producer or Half.new('producer', name .. ':producer'),
    consumer = opts.consumer or Half.new('consumer', name .. ':consumer'),
    capacity = opts.capacity_resource or Capacity.new(opts.capacity, name .. ':capacity'),
    pump_claim = opts.pump_claim,
    read_chunk_size = opts.read_chunk_size or opts.chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or opts.chunk_size or 4096,
    _fibers_flow = true,
  })
  f.inlet_handle = make_inlet(f, name .. ':inlet')
  f.outlet_handle = make_outlet(f, name .. ':outlet')
  return f
end

function Flow:inlet() return self.inlet_handle end
function Flow:outlet() return self.outlet_handle end

local function inspect_parts(flow, include_claim)
  local items = {
    { 'buffer', flow.buffer:inspect_op() },
    { 'producer', flow.producer:inspect_op() },
    { 'consumer', flow.consumer:inspect_op() },
    { 'capacity', flow.capacity:inspect_op() },
  }
  if include_claim and flow.pump_claim then items[#items + 1] = { 'claim', flow.pump_claim:inspect_op() } end
  return items
end

local function inspect_from_parts(flow, p)
  local buf, prod, cons, cap, claim = p.buffer, p.producer, p.consumer, p.capacity, p.claim
  local claim_bytes = claim and (claim.bytes or '') or ''
  return {
    flow = flow,
    buffer = buf,
    producer = prod,
    consumer = cons,
    capacity_state = cap,
    length = buf.length or 0,
    pending_length = buf.length or 0,
    data = buf.data or '',
    chunk_count = buf.chunk_count or 0,
    capacity = cap.limit,
    free = cap.free,
    writer_open = prod.open,
    reader_open = cons.open,
    read_error = prod.error,
    write_error = cons.error,
    inflight = claim and claim.id and { id = claim.id, bytes = claim.bytes or '' } or nil,
    inflight_length = #claim_bytes,
    drained = (buf.length or 0) == 0 and claim_bytes == '',
    buffer_version = buf.version,
    producer_version = prod.version,
    consumer_version = cons.version,
    capacity_version = cap.version,
    claim_version = claim and claim.version or nil,
    version = tostring(buf.version) .. ':' .. tostring(prod.version) .. ':' .. tostring(cons.version) .. ':' .. tostring(cap.version) .. ':' .. tostring(claim and claim.version or '-'),
  }
end

function Flow:inspect_op()
  return Op.named_all(inspect_parts(self, false)):map(function(parts) return inspect_from_parts(self, parts) end)
end

function Flow:pump_inspect_op()
  return Op.named_all(inspect_parts(self, true)):map(function(parts) return inspect_from_parts(self, parts) end)
end

local function empty_storage_op(flow)
  if not flow.pump_claim then return flow.buffer:empty_op():map(function() return true end) end
  return Op.named_all({
    { 'buffer', flow.buffer:empty_op() },
    { 'claim', flow.pump_claim:empty_op() },
  }):map(function() return true end)
end

function Flow:closed_op()
  return Op.named_all({
    { 'producer', self.producer:closed_op() },
    { 'consumer', self.consumer:closed_op() },
    { 'empty', empty_storage_op(self) },
  }):map(function() return true end)
end

function Flow:drained_op()
  return Op.choice(
    empty_storage_op(self):map(function() return true end),
    self.consumer:error_op():map(function(err) return nil, err end)
  )
end

function Flow:exit_op() return self:closed_op() end
function Flow:transfer_op(from, to) return transfer_item_op(self, from, to, 'flow:transfer_op') end
function Flow:transfer_inlet_op(from, to) return transfer_item_op(self:inlet(), from, to, 'flow:transfer_inlet_op') end
function Flow:transfer_outlet_op(from, to) return transfer_item_op(self:outlet(), from, to, 'flow:transfer_outlet_op') end

-- Result constructors -------------------------------------------------------

local Read = {}
function Read.data(bytes) return { kind = 'data', bytes = bytes or '' } end
function Read.error(err, partial) return { kind = 'error', error = err, partial = partial } end

local Write = {}
function Write.ok(n) return { kind = 'write', n = n or 0 } end
function Write.error(err) return { kind = 'error', error = err } end

local function public_write(r)
  if r.kind == 'write' then return r.n end
  return nil, r.error
end

local function public_read(r)
  if r.kind == 'data' then return r.bytes end
  return nil, r.error
end

local function public_read_with_partial(r)
  if r.kind == 'data' then return r.bytes end
  return nil, r.error, r.partial
end

-- Writes -------------------------------------------------------------------

local function write_gate(flow)
  return flow.producer:open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(false, err) end
    return flow.consumer:open_op(Errors.BROKEN_PIPE)
  end)
end

local function reserve_for(flow, bytes, mode)
  local n = #bytes
  return mode == 'some' and flow.capacity:reserve_some_op(n) or flow.capacity:reserve_op(n)
end

local function write_core_op(inlet, bytes, mode)
  bytes = as_bytes(bytes or '')
  mode = mode or 'all'
  if mode ~= 'all' and mode ~= 'some' then error('unknown Flow write mode ' .. tostring(mode), 2) end
  if bytes == '' then return Op.always(Write.ok(0)) end

  local flow = inlet.flow
  return write_gate(flow):and_then(function(ok, err)
    if not ok then return Op.always(Write.error(err)) end
    return reserve_for(flow, bytes, mode):and_then(function(n, reserve_err)
      if not n then return Op.always(Write.error(reserve_err)) end
      local prefix = mode == 'some' and string.sub(bytes, 1, n) or bytes
      return flow.buffer:append_op(prefix):map(function() return Write.ok(#prefix) end)
    end)
  end)
end

function Inlet:write_op(bytes) return write_core_op(self, bytes, 'all'):map(public_write) end
function Inlet:write_some_op(bytes) return write_core_op(self, bytes, 'some'):map(public_write) end
function Inlet:flush_op() return self.flow:drained_op() end
function Inlet:shutdown_op(reason) return self.flow.producer:shutdown_op(reason) end
function Inlet:inspect_op() return self.flow:inspect_op() end
function Inlet:exit_op() return self.flow:closed_op() end
function Inlet:transfer_op(from, to) return transfer_item_op(self, from, to, 'inlet:transfer_op') end

-- Reads --------------------------------------------------------------------

local ReadSpec = {}
function ReadSpec.some(max) return { mode = 'some', max = max } end
function ReadSpec.exactly(n) return { mode = 'exactly', n = n } end
function ReadSpec.all(opts) return { mode = 'all', max = read_all_max(opts or {}) } end
function ReadSpec.line(opts)
  opts = opts or {}
  return { mode = 'line', sep = as_sep(opts.sep), include_sep = opts.include_sep == true, limit = line_limit(opts) }
end

local function release_as(flow, bytes, make_result)
  return flow.capacity:release_op(#bytes):map(function() return make_result(bytes) end)
end

local function consume_as(flow, op, make_result)
  return op:and_then(function(bytes, err)
    if not bytes then return Op.always(Read.error(err)) end
    return release_as(flow, bytes, make_result or Read.data)
  end)
end

local function line_value(bytes, fact) return string.sub(bytes, 1, fact.value_n) end

local function line_hit_op(flow, spec)
  return flow.buffer:find_line_op(spec):and_then(function(fact, err)
    if not fact then return Op.always(Read.error(err)) end
    return consume_as(flow, flow.buffer:consume_op(fact.consume_n), function(bytes)
      return Read.data(line_value(bytes, fact))
    end)
  end)
end

local BUFFERED = {}

function BUFFERED.some(flow, spec)
  if spec.max == 0 then return Op.always(Read.data('')) end
  return consume_as(flow, flow.buffer:consume_some_op(spec.max))
end

function BUFFERED.exactly(flow, spec)
  if spec.n == 0 then return Op.always(Read.data('')) end
  return consume_as(flow, flow.buffer:consume_exactly_op(spec.n))
end

function BUFFERED.line(flow, spec) return line_hit_op(flow, spec) end

function BUFFERED.all(flow, spec)
  if spec.max == nil then return Op.never() end
  return flow.buffer:too_large_op(spec.max):map(function() return Read.error(Errors.TOO_LARGE) end)
end

local TERMINAL = {}

function TERMINAL.some(flow, spec, term_err)
  return Op.choice(
    BUFFERED.some(flow, spec),
    flow.buffer:empty_op():map(function() return Read.error(term_err) end)
  )
end

function TERMINAL.exactly(flow, spec, term_err)
  if spec.n == 0 then return Op.always(Read.data('')) end
  return Op.choice(
    BUFFERED.exactly(flow, spec),
    flow.buffer:consume_short_op(spec.n):and_then(function(partial)
      return release_as(flow, partial, function(bytes) return Read.error(term_err, bytes) end)
    end)
  )
end

function TERMINAL.line(flow, spec, term_err)
  return Op.choice(
    line_hit_op(flow, spec),
    flow.buffer:consume_unmatched_line_op(spec):and_then(function(partial)
      if partial ~= '' then return release_as(flow, partial, Read.data) end
      return Op.always(Read.error(term_err))
    end)
  )
end

function TERMINAL.all(flow, spec, term_err)
  return Op.choice(
    spec.max ~= nil and flow.buffer:too_large_op(spec.max):map(function() return Read.error(Errors.TOO_LARGE) end) or Op.never(),
    flow.buffer:consume_available_within_op(spec.max):and_then(function(bytes)
      if term_err and term_err ~= Errors.EOF then
        return release_as(flow, bytes, function(partial) return Read.error(term_err, partial) end)
      end
      return release_as(flow, bytes, Read.data)
    end)
  )
end

local function read_buffered_op(flow, spec)
  local f = BUFFERED[spec.mode]
  if not f then error('unknown Flow read mode ' .. tostring(spec.mode), 2) end
  return f(flow, spec)
end

local function read_terminal_op(flow, spec, term_err)
  local f = TERMINAL[spec.mode]
  if not f then error('unknown Flow read mode ' .. tostring(spec.mode), 2) end
  return f(flow, spec, term_err)
end

local function read_core_op(outlet, spec)
  local flow = outlet.flow
  return flow.consumer:open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(Read.error(err)) end
    return Op.choice(
      read_buffered_op(flow, spec),
      flow.producer:terminal_op(Errors.EOF):and_then(function(_, term_err)
        return read_terminal_op(flow, spec, term_err)
      end)
    )
  end)
end

function Outlet:read_some_op(max)
  return read_core_op(self, ReadSpec.some(as_count(max, 4096, 'Flow read size'))):map(public_read)
end

function Outlet:read_exactly_op(n)
  return read_core_op(self, ReadSpec.exactly(as_count(n, 0, 'Flow exact read size'))):map(public_read_with_partial)
end

function Outlet:read_line_op(opts) return read_core_op(self, ReadSpec.line(opts or {})):map(public_read) end
function Outlet:read_all_op(opts) return read_core_op(self, ReadSpec.all(opts or {})):map(public_read_with_partial) end
function Outlet:shutdown_op(reason) return self.flow.consumer:shutdown_op(reason) end
function Outlet:inspect_op() return self.flow:inspect_op() end
function Outlet:exit_op() return self.flow:closed_op() end
function Outlet:transfer_op(from, to) return transfer_item_op(self, from, to, 'outlet:transfer_op') end

-- Pump-facing operations ----------------------------------------------------

local function claim_id(flow, claim_state)
  -- Claim ids must not be based on byte length: future asynchronous backends may
  -- acknowledge old claims after another same-length claim has been created.
  -- The claim resource version is already the pump's sequencing fact.
  return tostring(flow._fibers_id) .. ':claim:' .. tostring((claim_state.version or 0) + 1)
end

function Outlet:claim_for_pump_op(max)
  max = as_count(max, 4096, 'Flow pump claim size')
  local flow = self.flow
  if not flow.pump_claim then error('claim_for_pump_op requires a pump claim on this Flow', 2) end

  local closed_and_drained = flow.producer:closed_op():and_then(function()
    return Op.named_all({
      { 'buffer', flow.buffer:empty_op() },
      { 'claim', flow.pump_claim:empty_op() },
    }):map(function() return nil, Errors.CLOSED_AND_DRAINED end)
  end)

  local claim_next_chunk = flow.buffer:consume_some_op(max):and_then(function(bytes)
    return flow.pump_claim:empty_op():and_then(function()
      return flow.pump_claim:inspect_op():and_then(function(st)
        local id = claim_id(flow, st)
        return flow.pump_claim:set_op(id, bytes):map(function() return id, bytes end)
      end)
    end)
  end)

  return Op.choice(
    flow.pump_claim:inflight_op(),
    flow.consumer:error_op():map(function(err) return nil, err end),
    claim_next_chunk,
    closed_and_drained
  )
end

function Outlet:ack_claim_op(id, n)
  local flow = self.flow
  if not flow.pump_claim then error('ack_claim_op requires a pump claim on this Flow', 2) end
  return flow.pump_claim:ack_op(id, n):and_then(function(ok, accepted_or_err)
    if not ok then return Op.always(nil, accepted_or_err) end
    return flow.capacity:release_op(accepted_or_err or n or 0):map(function() return true end)
  end)
end

function Outlet:fail_write_op(err) return self.flow.consumer:fail_op(err or Errors.WRITE_ERROR) end
function Outlet:fail_read_op(err) return self.flow.producer:fail_op(err or Errors.READ_ERROR) end

FlowFacility.new = Flow.new
FlowFacility.Flow = Flow
FlowFacility.Inlet = Inlet
FlowFacility.Outlet = Outlet
FlowFacility.Buffer = Buffer
FlowFacility.Half = Half
FlowFacility.Capacity = Capacity
FlowFacility.Errors = Errors

return FlowFacility
