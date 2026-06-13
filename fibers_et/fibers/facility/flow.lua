-- Transactional unidirectional byte flows.
--
-- Flow is the primitive byte facility:
--   Inlet  ->  Flow  ->  Outlet
--
-- A Flow is a compound built from smaller transactional resources:
--   ByteBuffer + Producer HalfState + Consumer HalfState + Capacity
-- Pump strategies may attach optional Claim state for irreversible host drains.

local Op = require('fibers.base.op')
local Region = require('fibers.base.region')
local Ownership = require('fibers.internal.ownership')
local Buffer = require('fibers.facility.flow.buffer')
local Half = require('fibers.facility.flow.half')
local Capacity = require('fibers.facility.flow.capacity')
local Errors = require('fibers.facility.flow.errors')

local unpack = table.unpack or unpack

local FlowFacility = {}
local Flow = {}; Flow.__index = Flow
local Inlet = {}; Inlet.__index = Inlet
local Outlet = {}; Outlet.__index = Outlet

local next_flow = 0
local DEFAULT_LINE_LIMIT = 64 * 1024

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

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then error('Flow bytes must be a string', 3) end
  return bytes
end
local function as_nonneg_int(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then error((label or 'Flow count') .. ' must be a non-negative integer', 3) end
  return n
end
local function validate_sep(sep)
  sep = sep or '\n'
  if type(sep) ~= 'string' or sep == '' then error('Flow line separator must be a non-empty string', 3) end
  return sep
end
local function validate_limit(limit, label)
  if limit == nil then return nil end
  return as_nonneg_int(limit, nil, label or 'Flow limit')
end
local function line_limit(opts)
  opts = opts or {}
  if opts.unlimited == true then return nil end
  if opts.limit == nil then return DEFAULT_LINE_LIMIT end
  return validate_limit(opts.limit, 'Flow line limit')
end
local function read_all_max(opts)
  opts = opts or {}
  if opts.unlimited == true then return nil end
  if opts.max == nil then error('read_all_op expects opts.max or opts.unlimited = true', 3) end
  return as_nonneg_int(opts.max, nil, 'Flow read_all max')
end

local function make_inlet(flow, name)
  local h = Ownership.handle(name, {
    kind = 'flow_inlet', flow = flow, _fibers_flow_inlet = true,
    _fibers_kind_name = 'flow_inlet', _fibers_obligation_kind = 'flow_inlet',
  })
  return setmetatable(h, Inlet)
end
local function make_outlet(flow, name)
  local h = Ownership.handle(name, {
    kind = 'flow_outlet', flow = flow, _fibers_flow_outlet = true,
    _fibers_kind_name = 'flow_outlet', _fibers_obligation_kind = 'flow_outlet',
  })
  return setmetatable(h, Outlet)
end

function Flow.new(opts)
  opts = opts or {}
  next_flow = next_flow + 1
  local name = opts.name or ('flow-' .. tostring(next_flow))
  local f = Ownership.handle(name, {
    kind = 'flow',
    buffer = opts.buffer or Buffer.new { name = name .. ':buffer' },
    producer = opts.producer or Half.new('producer', name .. ':producer'),
    consumer = opts.consumer or Half.new('consumer', name .. ':consumer'),
    capacity = opts.capacity_resource or Capacity.new(opts.capacity, name .. ':capacity'),
    pump_claim = opts.pump_claim,
    read_chunk_size = opts.read_chunk_size or opts.chunk_size or 4096,
    write_chunk_size = opts.write_chunk_size or opts.chunk_size or 4096,
    _fibers_flow = true, _fibers_kind_name = 'flow', _fibers_obligation_kind = 'flow',
  })
  setmetatable(f, Flow)
  f.inlet_handle = make_inlet(f, name .. ':inlet')
  f.outlet_handle = make_outlet(f, name .. ':outlet')
  return f
end

function Flow:inlet() return self.inlet_handle end
function Flow:outlet() return self.outlet_handle end

local function state_from_rows(flow, rows, claim_row)
  local buf, prod, cons, cap = rows[1][1], rows[2][1], rows[3][1], rows[4][1]
  local claim = claim_row and claim_row[1] or nil
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

function Flow:state_op()
  return Op.all({ self.buffer:state_op(), self.producer:state_op(), self.consumer:state_op(), self.capacity:state_op() })
    :map(function(rows) return state_from_rows(self, rows, nil) end)
end

function Flow:pump_state_op()
  if not self.pump_claim then return self:state_op() end
  return Op.all({ self.buffer:state_op(), self.producer:state_op(), self.consumer:state_op(), self.capacity:state_op(), self.pump_claim:state_op() })
    :map(function(rows) return state_from_rows(self, rows, rows[5]) end)
end

function Flow:changed_op(st)
  return Op.choice(
    self.buffer:changed_op(st and st.buffer_version),
    Op.choice(
      self.producer:changed_op(st and st.producer_version),
      Op.choice(self.consumer:changed_op(st and st.consumer_version), self.capacity:changed_op(st and st.capacity_version))
    )
  ):and_then(function() return self:state_op() end)
end

function Flow:pump_changed_op(st)
  local op = Op.choice(
    self.buffer:changed_op(st and st.buffer_version),
    Op.choice(
      self.producer:changed_op(st and st.producer_version),
      Op.choice(self.consumer:changed_op(st and st.consumer_version), self.capacity:changed_op(st and st.capacity_version))
    )
  )
  if self.pump_claim then op = Op.choice(op, self.pump_claim:changed_op(st and st.claim_version)) end
  return op:and_then(function() return self:pump_state_op() end)
end

function Flow:closed_op()
  local function loop()
    return self:pump_state_op():and_then(function(st)
      if st.reader_open == false and st.writer_open == false and st.drained then return Op.always(true) end
      return self:pump_changed_op(st):and_then(function() return loop() end)
    end)
  end
  return loop()
end
function Flow:drained_op()
  local function loop()
    return self:pump_state_op():and_then(function(st)
      if st.drained then return Op.always(true) end
      if st.write_error then return Op.always(nil, st.write_error) end
      return self:pump_changed_op(st):and_then(function() return loop() end)
    end)
  end
  return loop()
end
function Flow:exit_op() return self:closed_op() end
function Flow:transfer_op(from, to) return transfer_item_op(self, from, to, 'flow:transfer_op') end
function Flow:transfer_inlet_op(from, to) return transfer_item_op(self:inlet(), from, to, 'flow:transfer_inlet_op') end
function Flow:transfer_outlet_op(from, to) return transfer_item_op(self:outlet(), from, to, 'flow:transfer_outlet_op') end

local function consume_release_op(flow, n)
  return flow.buffer:consume_op(n):and_then(function(bytes, err)
    if not bytes then return Op.always(nil, err) end
    return flow.capacity:release_op(#bytes):map(function() return bytes end)
  end)
end

function Inlet:write_op(bytes)
  bytes = as_bytes(bytes or '')
  if bytes == '' then return Op.always(0) end
  local flow = self.flow
  return flow.producer:require_open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(nil, err) end
    return flow.consumer:require_open_op(Errors.BROKEN_PIPE):and_then(function(ok2, err2)
      if not ok2 then return Op.always(nil, err2) end
      return flow.capacity:reserve_op(#bytes):and_then(function(n, cap_err)
        if not n then return Op.always(nil, cap_err) end
        return flow.buffer:append_op(bytes):map(function() return #bytes end)
      end)
    end)
  end)
end

function Inlet:write_some_op(bytes)
  bytes = as_bytes(bytes or '')
  if bytes == '' then return Op.always(0) end
  local flow = self.flow
  return flow.producer:require_open_op(Errors.CLOSED):and_then(function(ok, err)
    if not ok then return Op.always(nil, err) end
    return flow.consumer:require_open_op(Errors.BROKEN_PIPE):and_then(function(ok2, err2)
      if not ok2 then return Op.always(nil, err2) end
      return flow.capacity:reserve_some_op(#bytes):and_then(function(n, cap_err)
        if not n then return Op.always(nil, cap_err) end
        local prefix = string.sub(bytes, 1, n)
        return flow.buffer:append_op(prefix):map(function() return n end)
      end)
    end)
  end)
end
function Inlet:flush_op() return self.flow:drained_op() end
function Inlet:shutdown_op(reason) return self.flow.producer:shutdown_op(reason) end
function Inlet:state_op() return self.flow:state_op() end
function Inlet:exit_op() return self.flow:closed_op() end
function Inlet:transfer_op(from, to) return transfer_item_op(self, from, to, 'inlet:transfer_op') end

local function outlet_observe(flow, buffer_op)
  return Op.all({ buffer_op, flow.producer:state_op(), flow.consumer:state_op() }):map(function(rows)
    local b, prod, cons = rows[1][1], rows[2][1], rows[3][1]
    if type(b) ~= 'table' then b = { length = rows[1][2] or b or 0, data = rows[1][1] or '', version = rows[1][3] or rows[1][2] } end
    return {
      buffer = b,
      length = b.length or 0,
      data = b.data or '',
      buffer_version = b.version,
      writer_open = prod.open,
      reader_open = cons.open,
      read_error = prod.error,
      write_error = cons.error,
      producer_version = prod.version,
      consumer_version = cons.version,
    }
  end)
end

local function wait_for_outlet_change(flow, obs, next_loop)
  return Op.choice(
    flow.buffer:changed_op(obs and obs.buffer_version),
    Op.choice(flow.producer:changed_op(obs and obs.producer_version), flow.consumer:changed_op(obs and obs.consumer_version))
  ):and_then(next_loop)
end

local function outlet_loop(flow, observe_op, classify)
  local function loop()
    return observe_op():and_then(function(obs)
      local action = classify(obs)
      if action.kind == 'return' then return Op.always(unpack(action.values or {})) end
      if action.kind == 'consume' then
        return consume_release_op(flow, action.n):map(function(bytes)
          if action.map then return action.map(bytes) end
          return bytes
        end)
      end
      return wait_for_outlet_change(flow, obs, function() return loop() end)
    end)
  end
  return loop()
end

function Outlet:read_some_op(max)
  max = as_nonneg_int(max, 4096, 'Flow read size')
  local flow = self.flow
  return outlet_loop(flow, function()
    return outlet_observe(flow, flow.buffer:length_op())
  end, function(st)
    if st.reader_open == false then return { kind = 'return', values = { nil, Errors.CLOSED } } end
    if max == 0 then return { kind = 'return', values = { '' } } end
    if (st.length or 0) > 0 then return { kind = 'consume', n = math.min(st.length, max) } end
    if st.read_error then return { kind = 'return', values = { nil, st.read_error } } end
    if not st.writer_open then return { kind = 'return', values = { nil, Errors.EOF } } end
    return { kind = 'wait' }
  end)
end

function Outlet:read_exactly_op(n)
  n = as_nonneg_int(n, 0, 'Flow exact read size')
  local flow = self.flow
  return outlet_loop(flow, function()
    return outlet_observe(flow, flow.buffer:peek_op(n))
  end, function(st)
    if st.reader_open == false then return { kind = 'return', values = { nil, Errors.CLOSED } } end
    if n == 0 then return { kind = 'return', values = { '' } } end
    if (st.length or 0) >= n then return { kind = 'consume', n = n } end
    if st.read_error or not st.writer_open then
      local partial = st.data or ''
      if #partial > 0 then
        return { kind = 'consume', n = #partial, map = function(bytes) return nil, st.read_error or Errors.EOF, bytes end }
      end
      return { kind = 'return', values = { nil, st.read_error or Errors.EOF, partial } }
    end
    return { kind = 'wait' }
  end)
end

function Outlet:read_line_op(opts)
  opts = opts or {}
  local sep = validate_sep(opts.sep or '\n')
  local include_sep = opts.include_sep == true
  local limit = line_limit(opts)
  local flow = self.flow
  return outlet_loop(flow, function()
    return outlet_observe(flow, flow.buffer:scan_op({ sep = sep, limit = limit }))
  end, function(st)
    if st.reader_open == false then return { kind = 'return', values = { nil, Errors.CLOSED } } end
    local scan = st.buffer
    local data = scan.data or ''
    if scan.found then
      if scan.limited then return { kind = 'return', values = { nil, Errors.LINE_TOO_LONG } } end
      local consume_n = scan.pos + #sep - 1
      local out_n = include_sep and consume_n or (scan.pos - 1)
      local line = string.sub(data, 1, out_n)
      return { kind = 'consume', n = consume_n, map = function() return line end }
    end
    if scan.limited then return { kind = 'return', values = { nil, Errors.LINE_TOO_LONG } } end
    if #data > 0 and not st.writer_open then return { kind = 'consume', n = #data } end
    if st.read_error then return { kind = 'return', values = { nil, st.read_error } } end
    if not st.writer_open then return { kind = 'return', values = { nil, Errors.EOF } } end
    return { kind = 'wait' }
  end)
end

function Outlet:read_all_op(opts)
  local max = read_all_max(opts or {})
  local flow = self.flow
  return outlet_loop(flow, function()
    return outlet_observe(flow, flow.buffer:peek_op(max and (max + 1) or nil))
  end, function(st)
    local data = st.data or ''
    if st.reader_open == false then return { kind = 'return', values = { nil, Errors.CLOSED } } end
    if max ~= nil and (st.length or #data) > max then return { kind = 'return', values = { nil, Errors.TOO_LARGE } } end
    if st.read_error then
      if #data > 0 then return { kind = 'consume', n = #data, map = function(bytes) return nil, st.read_error, bytes end } end
      return { kind = 'return', values = { nil, st.read_error, '' } }
    end
    if not st.writer_open then
      if #data > 0 then return { kind = 'consume', n = #data } end
      return { kind = 'return', values = { '' } }
    end
    return { kind = 'wait' }
  end)
end

function Outlet:shutdown_op(reason) return self.flow.consumer:shutdown_op(reason) end
function Outlet:state_op() return self.flow:state_op() end
function Outlet:exit_op() return self.flow:closed_op() end
function Outlet:transfer_op(from, to) return transfer_item_op(self, from, to, 'outlet:transfer_op') end

-- Pump-facing operations ----------------------------------------------------

function Outlet:claim_for_pump_op(max)
  max = as_nonneg_int(max, 4096, 'Flow pump claim size')
  local flow = self.flow
  if not flow.pump_claim then error('claim_for_pump_op requires a pump claim on this Flow', 2) end
  local function loop()
    return flow.pump_claim:state_op():and_then(function(claim)
      if claim and (claim.bytes or '') ~= '' then return Op.always(claim.id, claim.bytes) end
      return flow:pump_state_op():and_then(function(st)
        if st.write_error then return Op.always(nil, st.write_error) end
        if (st.length or 0) > 0 then
          local n = math.min(st.length, max)
          local id = tostring(flow._fibers_id) .. ':claim:' .. tostring(st.buffer_version) .. ':' .. tostring(st.claim_version or 0)
          return flow.buffer:consume_op(n):and_then(function(bytes, err)
            if not bytes then return Op.always(nil, err) end
            return flow.pump_claim:set_op(id, bytes):map(function() return id, bytes end)
          end)
        end
        if not st.writer_open then return Op.always(nil, Errors.CLOSED_AND_DRAINED) end
        return flow:pump_changed_op(st):and_then(function() return loop() end)
      end)
    end)
  end
  return loop()
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
