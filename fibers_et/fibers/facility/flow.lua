-- Transactional unidirectional byte flows.
--
-- A Flow is a directional byte medium:
--
--   Inlet  ->  Flow  ->  Outlet
--
-- Its algebraic core is a reservoir of retained bytes.  Bytes may be queued
-- or leased; capacity is an invariant over retained bytes.  Input and output
-- endpoint states govern whether bytes may enter or leave.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Ownership = require('fibers.internal.ownership')
local Settlement = require('fibers.internal.settlement')
local Reservoir = require('fibers.facility.flow.reservoir')
local Endpoint = require('fibers.facility.flow.endpoint')
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

local function as_term(term, default, label)
  term = term == nil and default or term
  if type(term) ~= 'string' or term == '' then error((label or 'Flow terminator') .. ' must be a non-empty string', 3) end
  return term
end

local function as_limit(n, label)
  if n == nil then return nil end
  return as_count(n, nil, label or 'Flow limit')
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
  if kind == 'flow' then
    fields.settle = fields.settle or Settlement.flow()
    fields.settle_name = fields.settle_name or 'flow'
  end
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
  -- Flush/drain waits until the fate of retained output bytes is known.  Empty
  -- retained storage is success.  If retained bytes are later discarded by
  -- settlement, callers observe that settlement error.  If the output endpoint
  -- becomes terminal while bytes are still retained, delivery is impossible.
  local start_version
  local function loop()
    return Op.named_all({
      { 'reservoir', self.reservoir:inspect_op() },
      { 'output', self.output:inspect_op() },
    }):and_then(function(parts)
      local res, output = parts.reservoir, parts.output
      start_version = start_version or res.version or 0
      if res.settled_error ~= nil and (res.settled_version or 0) > start_version then
        return Op.always(nil, res.settled_error)
      end
      if (res.retained_length or 0) == 0 then return Op.always(true) end
      if output.error then return Op.always(nil, output.error) end
      if not output.open then return Op.always(nil, Errors.BROKEN_PIPE) end
      return Op.choice(
        self.reservoir:changed_op(res.version):map(function() return 'reservoir' end),
        self.output:changed_op(output.version):map(function() return 'output' end)
      ):and_then(function() return loop() end)
    end)
  end
  return loop()
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

local Write = {}
function Write.ok(n) return { kind = 'write', n = n or 0 } end
function Write.error(err) return { kind = 'error', error = err } end

local function public_write(r)
  if r.kind == 'write' then return r.n end
  return nil, r.error
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
function Inlet:append_op(bytes) return self:write_op(bytes) end
function Inlet:append_some_op(bytes) return self:write_some_op(bytes) end
function Inlet:flush_op() return self.flow:drained_op() end
function Inlet:drain_op() return self.flow:drained_op() end
function Inlet:drained_op() return self.flow:drained_op() end
function Inlet:close_op(reason) return self.flow.input:close_op(reason) end
function Inlet:shutdown_op(reason) return self.flow.input:shutdown_op(reason) end
function Inlet:fail_op(err) return self.flow.input:fail_op(err) end
function Inlet:inspect_op() return self.flow:inspect_op() end
function Inlet:exit_op() return self.flow:closed_op() end
function Inlet:transfer_op(from, to) return transfer_item_op(self, from, to, 'inlet:transfer_op') end

-- Reads --------------------------------------------------------------------

-- Ordinary consuming reads are composed from one speculative view and, only if
-- selected, one committed reservoir free.  Peeks expose the view; reads, drops
-- and splices consume it.  The host pump deliberately remains lease-based.

local V = {}
function V.data(bytes, n) bytes = bytes or ''; return { bytes = bytes, consume = n == nil and #bytes or n } end
function V.err(err, partial, n) return { error = err, partial = partial, consume = n or 0 } end

local function public(v) if not v.error then return v.bytes end; return nil, v.error end
local function public_partial(v) if not v.error then return v.bytes end; return nil, v.error, v.partial end

local function consume(flow, v)
  local n = v.consume or 0
  if n == 0 then return Op.always(v) end
  return flow.reservoir:free_op(n):map(function(ok, err) return ok and v or V.err(err) end)
end

local function read(flow, view_op) return view_op:and_then(function(v) return consume(flow, v) end) end

local function gated(outlet, body)
  local flow = outlet.flow
  return flow.output:open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(V.err(err)) end
    return body(flow)
  end)
end

local function view_some(outlet, max)
  return gated(outlet, function(flow)
    if max == 0 then return Op.always(V.data('', 0)) end
    return Op.choice(
      flow.reservoir:peek_some_op(max):map(function(bytes, err) return bytes and V.data(bytes) or V.err(err) end),
      flow.input:terminal_op(Errors.EOF):and_then(function(_, term_err)
        return flow.reservoir:peek_available_op(max):map(function(bytes)
          return bytes ~= '' and V.data(bytes) or V.err(term_err)
        end)
      end)
    )
  end)
end

local function view_exactly(outlet, n)
  return gated(outlet, function(flow)
    if n == 0 then return Op.always(V.data('', 0)) end
    return Op.choice(
      flow.reservoir:peek_exactly_op(n):map(function(bytes, err) return bytes and V.data(bytes, n) or V.err(err) end),
      flow.input:terminal_op(Errors.EOF):and_then(function(_, term_err)
        return flow.reservoir:peek_available_op(n):map(function(bytes)
          return #bytes >= n and V.data(bytes, n) or V.err(term_err, bytes, #bytes)
        end)
      end)
    )
  end)
end

local function read_all_limit(opts)
  opts = opts or {}
  if opts.unlimited == true then return nil end
  if opts.max == nil then error('read_all_op expects opts.max or opts.unlimited = true', 3) end
  return as_limit(opts.max, 'Flow read_all max')
end

local function view_all_loop(outlet, max)
  local flow = outlet.flow
  return flow.reservoir:inspect_op():and_then(function(snap)
    local data = snap.data or ''
    if max ~= nil and #data > max then return Op.always(V.err(Errors.TOO_LARGE)) end
    return Op.choice(
      flow.input:terminal_op(Errors.EOF):and_then(function(_, term_err)
        if data == '' then return Op.always(V.err(term_err)) end
        if term_err and term_err ~= Errors.EOF then return Op.always(V.err(term_err, data, #data)) end
        return Op.always(V.data(data))
      end),
      flow.reservoir:changed_op(snap.version):and_then(function() return view_all_loop(outlet, max) end)
    )
  end)
end

local function view_all(outlet, max) return gated(outlet, function() return view_all_loop(outlet, max) end) end

local function delimiter(term, opts, include)
  opts = opts or {}
  local partial = opts.partial or 'error'
  if partial ~= 'error' and partial ~= 'return' and partial ~= 'discard' then
    error('Flow partial policy must be error, return or discard', 3)
  end
  local limit = opts.unlimited == true and nil or (opts.limit == nil and DEFAULT_LINE_LIMIT or as_limit(opts.limit, 'Flow delimiter limit'))
  return {
    term = as_term(term, nil, 'Flow terminator'), include = include == true,
    limit = limit, partial = partial, too_large = opts.too_large_error or Errors.TOO_LARGE,
  }
end

local function suffix_prefix_len(data, term)
  for n = math.min(#data, #term - 1), 1, -1 do
    if string.sub(data, #data - n + 1) == string.sub(term, 1, n) then return n end
  end
  return 0
end

local function delimiter_too_large(data, spec)
  if spec.limit == nil then return false end
  local pos = string.find(data, spec.term, 1, true)
  if pos then return pos - 1 > spec.limit end
  return #data - suffix_prefix_len(data, spec.term) > spec.limit
end

local function terminal_delimited(spec, term_err, data)
  data = data or ''
  if data == '' then return V.err(term_err) end
  if spec.partial == 'return' then return V.data(data, #data) end
  if spec.partial == 'discard' then return V.err(term_err, nil, #data) end
  return V.err(term_err, data, #data)
end

local function view_delimited_loop(outlet, spec)
  local flow = outlet.flow
  return flow.reservoir:inspect_op():and_then(function(snap)
    local data = snap.data or ''
    local pos, last = string.find(data, spec.term, 1, true)
    if delimiter_too_large(data, spec) then return Op.always(V.err(spec.too_large)) end
    if pos then return Op.always(V.data(string.sub(data, 1, spec.include and last or pos - 1), last)) end
    return Op.choice(
      flow.input:terminal_op(Errors.EOF):and_then(function(_, term_err)
        return Op.always(terminal_delimited(spec, term_err, data))
      end),
      flow.reservoir:changed_op(snap.version):and_then(function() return view_delimited_loop(outlet, spec) end)
    )
  end)
end

local function view_delimited(outlet, spec) return gated(outlet, function() return view_delimited_loop(outlet, spec) end) end

function Outlet:read_some_op(max) return read(self.flow, view_some(self, as_count(max, 4096, 'Flow read size'))):map(public) end
function Outlet:read_op(max) return self:read_some_op(max) end
function Outlet:read_exactly_op(n) return read(self.flow, view_exactly(self, as_count(n, 0, 'Flow exact read size'))):map(public_partial) end
function Outlet:read_all_op(opts) return read(self.flow, view_all(self, read_all_limit(opts or {}))):map(public_partial) end

function Outlet:peek_some_op(max) return view_some(self, as_count(max, 4096, 'Flow peek size')):map(public) end
function Outlet:peek_exactly_op(n) return view_exactly(self, as_count(n, 0, 'Flow exact peek size')):map(public_partial) end
function Outlet:peek_op(n) return self:peek_exactly_op(as_count(n, 0, 'Flow peek size')) end

function Outlet:read_until_op(term, opts) return read(self.flow, view_delimited(self, delimiter(term, opts or {}, false))):map(public_partial) end
function Outlet:read_including_op(term, opts) return read(self.flow, view_delimited(self, delimiter(term, opts or {}, true))):map(public_partial) end
function Outlet:read_line_op(opts)
  opts = opts or {}
  local line_opts = {}; for k, v in pairs(opts) do line_opts[k] = v end
  line_opts.partial = line_opts.partial or 'return'
  line_opts.too_large_error = line_opts.too_large_error or Errors.LINE_TOO_LONG
  return (opts.include_sep == true and self.read_including_op or self.read_until_op)(self, as_term(opts.sep, '\n', 'Flow line separator'), line_opts)
end

function Outlet:drop_op(n)
  return read(self.flow, view_exactly(self, as_count(n, 0, 'Flow drop size'))):map(function(v)
    if v.error then return nil, v.error, v.partial end
    return v.consume or #v.bytes
  end)
end

function Outlet:splice_to(inlet, max)
  if not inlet or not inlet.flow or not inlet.write_op then error('Outlet:splice_to expects an Inlet', 2) end
  return view_some(self, as_pos_count(max, self.flow.read_chunk_size or 4096, 'Flow splice size')):and_then(function(v)
    if v.error then return Op.always(nil, v.error, v.partial) end
    return inlet:write_op(v.bytes):and_then(function(n, err)
      if not n then return Op.always(nil, err) end
      return consume(self.flow, V.data(v.bytes, n)):map(function(done)
        return done.error and nil or n, done.error
      end)
    end)
  end)
end

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
FlowFacility.Lease = Lease
FlowFacility.Errors = Errors

return FlowFacility
