-- Transactional unidirectional byte flows.
--
-- A Flow is a directional byte medium:
--
--   Inlet  ->  Flow  ->  Outlet
--
-- Its algebraic core is a reservoir of byte segments.  Segments may be queued
-- or leased; capacity is an invariant over retained segments.  Input and output
-- endpoint states govern whether bytes may enter or leave.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Ownership = require('fibers.internal.ownership')
local Reservoir = require('fibers.facility.flow.reservoir')
local Endpoint = require('fibers.facility.flow.endpoint')
local Segment = require('fibers.facility.flow.segment')
local Lease = require('fibers.facility.flow.lease')
local Errors = require('fibers.facility.flow.errors')

local FlowFacility = {}
local Flow = {}; Flow.__index = Flow
local Inlet = {}; Inlet.__index = Inlet
local Outlet = {}; Outlet.__index = Outlet

local next_flow = 0
local DEFAULT_LINE_LIMIT = 64 * 1024

-- Validation and ownership --------------------------------------------------

local function as_bytes(bytes)
  if Segment.is(bytes) then return Segment.bytes(bytes) end
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

local function as_pos_count(n, default, label)
  n = as_count(n, default, label)
  if n <= 0 then error((label or 'Flow count') .. ' must be positive', 3) end
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
    reservoir = opts.reservoir or Reservoir.new { name = name .. ':reservoir', capacity = opts.capacity },
    input = opts.input or Endpoint.new('input', name .. ':input'),
    output = opts.output or Endpoint.new('output', name .. ':output'),
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

local function inspect_from_parts(flow, p)
  local res, input, output = p.reservoir, p.input, p.output
  return {
    flow = flow,
    reservoir = res,
    input = input,
    output = output,
    length = res.queued_length or res.length or 0,
    queued_length = res.queued_length or res.length or 0,
    pending_length = res.queued_length or res.length or 0,
    leased_length = res.leased_length or 0,
    retained_length = res.retained_length or ((res.queued_length or res.length or 0) + (res.leased_length or 0)),
    data = res.data or '',
    segment_count = res.segment_count or res.chunk_count or 0,
    chunk_count = res.chunk_count or res.segment_count or 0,
    capacity = res.capacity or res.limit,
    free = res.free,
    writer_open = input.open,
    reader_open = output.open,
    read_error = input.error,
    write_error = output.error,
    leases = res.leases,
    lease_count = res.lease_count or 0,
    inflight = res.lease_count and res.lease_count > 0 and res.leases or nil,
    inflight_length = res.leased_length or 0,
    drained = (res.queued_length or res.length or 0) == 0 and (res.leased_length or 0) == 0,
    reservoir_version = res.version,
    input_version = input.version,
    output_version = output.version,
    version = tostring(res.version) .. ':' .. tostring(input.version) .. ':' .. tostring(output.version),
  }
end

function Flow:inspect_op()
  return Op.named_all({
    { 'reservoir', self.reservoir:inspect_op() },
    { 'input', self.input:inspect_op() },
    { 'output', self.output:inspect_op() },
  }):map(function(parts) return inspect_from_parts(self, parts) end)
end

function Flow:pump_inspect_op() return self:inspect_op() end

local function empty_storage_op(flow) return flow.reservoir:empty_op():map(function() return true end) end

function Flow:closed_op()
  return Op.named_all({
    { 'input', self.input:closed_op() },
    { 'output', self.output:closed_op() },
    { 'empty', empty_storage_op(self) },
  }):map(function() return true end)
end

function Flow:drained_op()
  -- Flush/drain waits until the fate of retained output bytes is known.  The
  -- happy path is empty retained storage.  If the output endpoint reaches a
  -- terminal state first, delivery has become impossible and callers observe
  -- that terminal error instead of waiting for an acknowledgement that can no
  -- longer arrive.
  return Op.choice(
    self.output:terminal_op(Errors.BROKEN_PIPE),
    empty_storage_op(self):map(function() return true end)
  )
end

function Flow:close_op(reason) return self:shutdown_op(reason) end
function Flow:shutdown_op(reason)
  return Op.named_all({
    { 'input', self.input:shutdown_op(reason) },
    { 'output', self.output:shutdown_op(reason) },
    { 'settle', self.reservoir:settle_op(reason or Errors.BROKEN_PIPE) },
  }):map(function() return true end)
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
  return flow.input:open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(false, err) end
    return flow.output:open_op(Errors.BROKEN_PIPE)
  end)
end

local function append_for(flow, bytes, mode)
  return mode == 'some' and flow.reservoir:append_some_op(bytes) or flow.reservoir:append_op(bytes)
end

local function write_core_op(inlet, bytes, mode)
  bytes = as_bytes(bytes or '')
  mode = mode or 'all'
  if mode ~= 'all' and mode ~= 'some' then error('unknown Flow write mode ' .. tostring(mode), 2) end
  if bytes == '' then return Op.always(Write.ok(0)) end

  local flow = inlet.flow
  return write_gate(flow):and_then(function(ok, err)
    if not ok then return Op.always(Write.error(err)) end
    return append_for(flow, bytes, mode):map(function(n, append_err)
      if not n then return Write.error(append_err) end
      return Write.ok(n)
    end)
  end)
end

function Inlet:write_op(bytes) return write_core_op(self, bytes, 'all'):map(public_write) end
function Inlet:write_some_op(bytes) return write_core_op(self, bytes, 'some'):map(public_write) end
function Inlet:flush_op() return self.flow:drained_op() end
function Inlet:drained_op() return self.flow:drained_op() end
function Inlet:close_op(reason) return self.flow.input:close_op(reason) end
function Inlet:shutdown_op(reason) return self.flow.input:shutdown_op(reason) end
function Inlet:fail_op(err) return self.flow.input:fail_op(err) end
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

local function consume_as(flow, op, make_result)
  return op:map(function(bytes, err)
    if not bytes then return Read.error(err) end
    return (make_result or Read.data)(bytes)
  end)
end

local function line_value(bytes, fact) return string.sub(bytes, 1, fact.value_n) end

local function line_hit_op(flow, spec)
  return flow.reservoir:find_line_op(spec):and_then(function(fact, err)
    if not fact then return Op.always(Read.error(err)) end
    return consume_as(flow, flow.reservoir:consume_op(fact.consume_n), function(bytes)
      return Read.data(line_value(bytes, fact))
    end)
  end)
end

local BUFFERED = {}
function BUFFERED.some(flow, spec)
  if spec.max == 0 then return Op.always(Read.data('')) end
  return consume_as(flow, flow.reservoir:consume_some_op(spec.max))
end
function BUFFERED.exactly(flow, spec)
  if spec.n == 0 then return Op.always(Read.data('')) end
  return consume_as(flow, flow.reservoir:consume_exactly_op(spec.n))
end
function BUFFERED.line(flow, spec) return line_hit_op(flow, spec) end
function BUFFERED.all(flow, spec)
  if spec.max == nil then return Op.never() end
  return flow.reservoir:too_large_op(spec.max):map(function() return Read.error(Errors.TOO_LARGE) end)
end

local TERMINAL = {}
function TERMINAL.some(flow, spec, term_err)
  return Op.choice(
    BUFFERED.some(flow, spec),
    flow.reservoir:queued_empty_op():map(function() return Read.error(term_err) end)
  )
end
function TERMINAL.exactly(flow, spec, term_err)
  if spec.n == 0 then return Op.always(Read.data('')) end
  return Op.choice(
    BUFFERED.exactly(flow, spec),
    flow.reservoir:consume_short_op(spec.n):map(function(partial) return Read.error(term_err, partial) end)
  )
end
function TERMINAL.line(flow, spec, term_err)
  return Op.choice(
    line_hit_op(flow, spec),
    flow.reservoir:consume_unmatched_line_op(spec):map(function(partial)
      if partial ~= '' then return Read.data(partial) end
      return Read.error(term_err)
    end)
  )
end
function TERMINAL.all(flow, spec, term_err)
  return Op.choice(
    spec.max ~= nil and flow.reservoir:too_large_op(spec.max):map(function() return Read.error(Errors.TOO_LARGE) end) or Op.never(),
    flow.reservoir:consume_available_within_op(spec.max):map(function(bytes, err)
      if not bytes then return Read.error(err) end
      if term_err and term_err ~= Errors.EOF then return Read.error(term_err, bytes) end
      return Read.data(bytes)
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
  return flow.output:open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(Read.error(err)) end
    return Op.choice(
      read_buffered_op(flow, spec),
      flow.input:terminal_op(Errors.EOF):and_then(function(_, term_err)
        return read_terminal_op(flow, spec, term_err)
      end)
    )
  end)
end

function Outlet:read_some_op(max) return read_core_op(self, ReadSpec.some(as_count(max, 4096, 'Flow read size'))):map(public_read) end
function Outlet:read_op(max) return self:read_some_op(max) end
function Outlet:read_exactly_op(n) return read_core_op(self, ReadSpec.exactly(as_count(n, 0, 'Flow exact read size'))):map(public_read_with_partial) end
function Outlet:read_line_op(opts) return read_core_op(self, ReadSpec.line(opts or {})):map(public_read) end
function Outlet:read_all_op(opts) return read_core_op(self, ReadSpec.all(opts or {})):map(public_read_with_partial) end
function Outlet:close_op(reason) return self:shutdown_op(reason) end
function Outlet:shutdown_op(reason)
  local flow = self.flow
  return Op.named_all({
    { 'output', flow.output:shutdown_op(reason) },
    { 'settle', flow.reservoir:settle_op(reason or Errors.BROKEN_PIPE) },
  }):map(function() return true end)
end
function Outlet:fail_op(err)
  local flow = self.flow
  local e = err or Errors.FLOW_ERROR
  return Op.named_all({
    { 'output', flow.output:fail_op(e) },
    { 'settle', flow.reservoir:settle_op(e) },
  }):map(function() return true end)
end
function Outlet:inspect_op() return self.flow:inspect_op() end
function Outlet:exit_op() return self.flow:closed_op() end
function Outlet:transfer_op(from, to) return transfer_item_op(self, from, to, 'outlet:transfer_op') end

-- Lease-facing operations ---------------------------------------------------

function Outlet:lease_some_op(max, owner)
  max = as_pos_count(max, 4096, 'Flow lease size')
  local flow = self.flow
  local lease_owner = owner or self
  local closed_and_drained = flow.input:closed_op():and_then(function()
    return flow.reservoir:empty_op():map(function() return nil, Errors.CLOSED_AND_DRAINED end)
  end)

  return Op.choice(
    flow.reservoir:lease_some_op(lease_owner, max),
    flow.output:error_op():map(function(err) return nil, err end),
    closed_and_drained
  )
end

function Outlet:leased_op(owner) return self.flow.reservoir:lease_existing_op(owner or self) end
function Outlet:lease_empty_op() return self.flow.reservoir:leases_empty_op() end
function Outlet:ack_lease_op(lease, n)
  return self.flow.reservoir:ack_lease_op(lease, n):map(function(ok, err_or_n, remaining)
    if not ok then return nil, err_or_n end
    return true, err_or_n, remaining
  end)
end
function Outlet:return_lease_op(lease) return self.flow.reservoir:return_lease_op(lease) end
function Outlet:fail_lease_op(lease, err) return self.flow.reservoir:fail_lease_op(lease, err) end
function Outlet:fail_write_op(err) return self:fail_op(err or Errors.WRITE_ERROR) end
function Outlet:fail_read_op(err) return self.flow.input:fail_op(err or Errors.READ_ERROR) end

FlowFacility.new = Flow.new
FlowFacility.Flow = Flow
FlowFacility.Inlet = Inlet
FlowFacility.Outlet = Outlet
FlowFacility.Reservoir = Reservoir
FlowFacility.Endpoint = Endpoint
FlowFacility.Segment = Segment
FlowFacility.Lease = Lease
FlowFacility.Errors = Errors

return FlowFacility
