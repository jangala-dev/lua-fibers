-- Scalar-state-machine Flow.
--
-- This is the atom-built Flow v1. Endpoint gates are Scalars and the byte
-- reservoir is one typed Scalar state machine. Reads use typed select
-- transitions so same-world writes can hand off under tensor but not under all.

local Op = require('fibers.atoms.op')
local Scalar = require('fibers.atoms.scalar')
local Rope = require('fibers.flow.rope')
local Lease = require('fibers.flow.lease')
local Errors = require('fibers.flow.errors')
local Ownership = require('fibers.internal.ownership')
local Runtime = require('fibers.kernel.runtime')

local Flow = {}
Flow.__index = Flow

local Inlet = {}
Inlet.__index = Inlet
local Outlet = {}
Outlet.__index = Outlet
local Reservoir = {}
Reservoir.__index = Reservoir

local next_id = 0
local INF = math.huge

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then error('flow bytes must be a string', 3) end
  return bytes
end
local function as_nonneg_int(n, default, label)
  if n == nil then n = default end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'flow byte count') .. ' must be a non-negative integer', 3)
  end
  return n
end
local function as_pos_int(n, default, label)
  n = as_nonneg_int(n, default, label)
  if n <= 0 then error((label or 'flow byte count') .. ' must be positive', 3) end
  return n
end
local function as_capacity(n)
  if n == nil then return nil end
  return as_nonneg_int(n, nil, 'flow capacity')
end

local function copy_leases(src)
  local out = {}
  for id, l in pairs(src or {}) do
    out[id] = { id = l.id, owner = l.owner, bytes = l.bytes or '', meta = l.meta }
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
local function clone_state(s)
  s = s or {}
  return {
    rope = Rope.is(s.rope) and s.rope:clone() or Rope.new(),
    leases = copy_leases(s.leases),
    next_lease = s.next_lease or 0,
    settled_error = s.settled_error,
    settled_version = s.settled_version or 0,
  }
end
local function inspect_state(self, s)
  local queued = s.rope:length()
  local leased = leased_length(s.leases)
  local retained = queued + leased
  local cap = self.capacity or INF
  return {
    queued = queued,
    queued_length = queued,
    leased = leased,
    retained = retained,
    capacity = self.capacity,
    free = cap == INF and INF or cap - retained,
    leases = lease_count(s.leases),
    chunk_count = s.rope:chunk_count(),
    data = s.rope:tostring(),
    settled_error = s.settled_error,
    settled_version = s.settled_version or 0,
  }
end
local function free_bytes(self, s)
  if not self.capacity then return INF end
  return self.capacity - (s.rope:length() + leased_length(s.leases))
end
local function lease_handle(self, l)
  return Lease.new(self, l.id, l.owner, l.bytes, { meta = l.meta })
end

local function free_for_capacity(capacity, s)
  if not capacity then return INF end
  return capacity - (s.rope:length() + leased_length(s.leases))
end

local function find_until(s, sep)
  local pos = s.rope:find(sep)
  return pos and (pos + #sep) or nil, pos
end
local function ends_with_separator_prefix(data, sep)
  local max = math.min(#data, #sep - 1)
  for n = max, 1, -1 do
    if data:sub(#data - n + 1) == sep:sub(1, n) then return true end
  end
  return false
end

local ReservoirTransitions = Scalar.kind {
  name = 'flow.reservoir',
  transitions = {
    append = {
      mode = 'select',
      order = 0,
      step = function(s, p)
        s = clone_state(s)
        local bytes = p.bytes or ''
        if p.capacity and #bytes > p.capacity then return s, false, Errors.CAPACITY end
        local free = free_for_capacity(p.capacity, s)
        if #bytes > free then return nil end
        s.rope:append(bytes)
        return s, true, #bytes
      end,
    },
    append_some = {
      mode = 'update',
      order = 0,
      step = function(s, p)
        s = clone_state(s)
        local bytes = p.bytes or ''
        local free = free_for_capacity(p.capacity, s)
        if free <= 0 or #bytes == 0 then return s, 0, bytes end
        local n = math.min(#bytes, free)
        s.rope:append(bytes:sub(1, n))
        return s, n, bytes:sub(n + 1)
      end,
    },
    read_some = {
      mode = 'select',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        if s.rope:is_empty() then return nil end
        local bytes = s.rope:take(math.min(p.n, s.rope:length()))
        return s, bytes
      end,
    },
    lease = {
      mode = 'select',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        local has_lease = false
        if p.owner ~= nil then
          for _, l in pairs(s.leases or {}) do
            has_lease = true
            if l.owner == p.owner then return s, lease_handle(p.reservoir, l) end
          end
        else
          for _ in pairs(s.leases or {}) do has_lease = true; break end
        end
        if has_lease then return s, nil, Errors.LEASE_ALREADY_ACTIVE end
        if s.rope:is_empty() then return nil end
        local bytes = s.rope:take(math.min(p.n, s.rope:length()))
        s.next_lease = (s.next_lease or 0) + 1
        local id = (p.flow_id or 'flow') .. ':lease:' .. tostring(s.next_lease)
        s.leases[id] = { id = id, owner = p.owner, bytes = bytes, meta = p.meta }
        return s, lease_handle(p.reservoir, s.leases[id])
      end,
    },
    ack_lease = {
      mode = 'update',
      order = 0,
      step = function(s, p)
        s = clone_state(s)
        local l = s.leases[p.lease.id]
        if not l then return s, false, Errors.NO_LEASE end
        if p.n > #(l.bytes or '') then return s, false, Errors.LEASE_ACK_TOO_LARGE end
        l.bytes = (l.bytes or ''):sub(p.n + 1)
        if l.bytes == '' then s.leases[p.lease.id] = nil end
        return s, true, p.n
      end,
    },
    return_lease = {
      mode = 'update',
      order = 0,
      step = function(s, p)
        s = clone_state(s)
        local l = s.leases[p.lease.id]
        if not l then return s, false, Errors.NO_LEASE end
        s.rope:prepend(l.bytes or '')
        s.leases[p.lease.id] = nil
        return s, true, #(l.bytes or '')
      end,
    },
    fail_lease = {
      mode = 'update',
      order = 0,
      step = function(s, p)
        s = clone_state(s)
        local l = s.leases[p.lease.id]
        if not l then return s, false, Errors.NO_LEASE end
        s.leases[p.lease.id] = nil
        s.settled_error = p.err or Errors.FLOW_ERROR
        s.settled_version = (s.settled_version or 0) + 1
        return s, true, #(l.bytes or '')
      end,
    },
    capacity_some = {
      mode = 'select',
      order = 100,
      validate = function(p)
        if p.n == nil or p.n <= 0 then error('flow capacity count must be positive', 2) end
      end,
      step = function(s, p)
        s = clone_state(s)
        local free = free_for_capacity(p.capacity, s)
        if free <= 0 then return nil end
        return s, math.min(p.n, free)
      end,
    },
    peek = {
      mode = 'select',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        if s.rope:length() < p.n then return nil end
        return s, s.rope:peek(p.n)
      end,
    },
    read_exactly = {
      mode = 'select',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        if s.rope:length() < p.n then return nil end
        return s, s.rope:take(p.n)
      end,
    },
    read_until = {
      mode = 'select',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        local end_pos, data_len = find_until(s, p.sep)
        if end_pos then
          if p.limit and data_len > p.limit then return s, nil, (p.err or Errors.TOO_LARGE) end
          local out = s.rope:take(end_pos)
          if p.include then return s, out end
          return s, out:sub(1, #out - #p.sep)
        end
        if p.limit and s.rope:length() > p.limit then
          local data = s.rope:tostring()
          if not ends_with_separator_prefix(data, p.sep) then return s, nil, (p.err or Errors.TOO_LARGE) end
        end
        return nil
      end,
    },
    drain_available = {
      mode = 'update',
      order = 100,
      step = function(s)
        s = clone_state(s)
        local data = s.rope:take(s.rope:length())
        return s, data
      end,
    },
    read_all_too_large = {
      mode = 'select',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        if p.unlimited or not p.max or s.rope:length() <= p.max then return nil end
        return s, nil, Errors.TOO_LARGE
      end,
    },
    drain_all_limited = {
      mode = 'update',
      order = 100,
      step = function(s, p)
        s = clone_state(s)
        local len = s.rope:length()
        if not p.unlimited and p.max and len > p.max then return s, nil, Errors.TOO_LARGE end
        local data = s.rope:take(len)
        return s, data
      end,
    },
    settled_error = {
      mode = 'select',
      order = 100,
      step = function(s)
        s = clone_state(s)
        if not s.settled_error then return nil end
        return s, s.settled_error
      end,
    },
    settle = {
      mode = 'update',
      order = 0,
      step = function(s, p)
        s = clone_state(s)
        local retained = s.rope:length() + leased_length(s.leases)
        s.rope:reset()
        s.leases = {}
        if retained > 0 then
          s.settled_error = p.err or Errors.FLOW_ERROR
          s.settled_version = (s.settled_version or 0) + 1
        end
        return s, true
      end,
    },
    empty = {
      mode = 'select',
      order = 100,
      step = function(s)
        s = clone_state(s)
        if s.rope:length() + leased_length(s.leases) ~= 0 then return nil end
        return s, true
      end,
    },
  },
}

local function rtransition(self, name, payload)
  payload = payload or {}
  payload.capacity = self.capacity
  payload.reservoir = self
  payload.flow_id = self.flow and self.flow._fibers_id
  return self.state:transition_op(ReservoirTransitions:transition(name), payload)
end

function Reservoir.new(flow, opts)
  opts = opts or {}
  local cap = as_capacity(opts.capacity)
  local r = setmetatable({
    flow = flow,
    capacity = cap,
    limit = cap,
  }, Reservoir)
  r.state = Scalar.new({ rope = Rope.new(), leases = {}, next_lease = 0, settled_version = 0 }, (flow.name or 'flow') .. ':reservoir')
  return r
end

function Reservoir:inspect_op()
  return self.state:read_op():map(function(s) return inspect_state(self, s) end)
end

function Reservoir:append_op(bytes)
  bytes = as_bytes(bytes)
  return rtransition(self, 'append', { bytes = bytes })
end

function Reservoir:append_some_op(bytes)
  bytes = as_bytes(bytes)
  return rtransition(self, 'append_some', { bytes = bytes })
end

function Reservoir:read_some_op(n)
  n = as_pos_int(n, 1, 'flow read size')
  return rtransition(self, 'read_some', { n = n })
end

function Reservoir:peek_op(n)
  n = as_nonneg_int(n, 1, 'flow peek size')
  if n == 0 then return Op.always('') end
  return rtransition(self, 'peek', { n = n })
end

function Reservoir:read_exactly_op(n)
  n = as_nonneg_int(n, 0, 'flow exact read size')
  if n == 0 then return Op.always('') end
  return rtransition(self, 'read_exactly', { n = n })
end

function Reservoir:read_until_op(sep, opts)
  opts = opts or {}
  if type(sep) ~= 'string' or sep == '' then error('flow read_until separator must be non-empty string', 2) end
  local limit = opts.limit
  if limit ~= nil then limit = as_nonneg_int(limit, nil, 'flow read limit') end
  return rtransition(self, 'read_until', { sep = sep, limit = limit, include = opts.include == true, err = opts.err })
end

function Reservoir:drain_available_op()
  return rtransition(self, 'drain_available')
end

function Reservoir:read_all_limited_op(opts)
  opts = opts or {}
  return rtransition(self, 'drain_all_limited', { max = opts.max, unlimited = opts.unlimited == true })
end

function Reservoir:read_all_too_large_op(opts)
  opts = opts or {}
  return rtransition(self, 'read_all_too_large', { max = opts.max, unlimited = opts.unlimited == true })
end

function Reservoir:capacity_some_op(n)
  n = as_pos_int(n, 1, 'flow capacity count')
  return rtransition(self, 'capacity_some', { n = n })
end

function Reservoir:lease_op(n, owner, meta)
  n = as_pos_int(n, 1, 'flow lease size')
  return rtransition(self, 'lease', { n = n, owner = owner, meta = meta })
end

function Reservoir:ack_lease_op(lease, n)
  if not Lease.is(lease) then error('ack_lease_op expects a flow lease', 2) end
  n = as_nonneg_int(n, lease:length(), 'flow lease ack count')
  return rtransition(self, 'ack_lease', { lease = lease, n = n })
end

function Reservoir:return_lease_op(lease)
  if not Lease.is(lease) then error('return_lease_op expects a flow lease', 2) end
  return rtransition(self, 'return_lease', { lease = lease })
end

function Reservoir:fail_lease_op(lease, err)
  if not Lease.is(lease) then error('fail_lease_op expects a flow lease', 2) end
  return rtransition(self, 'fail_lease', { lease = lease, err = err })
end

function Reservoir:settle_op(err)
  return rtransition(self, 'settle', { err = err })
end

function Reservoir:settled_error_op()
  return rtransition(self, 'settled_error')
end

function Reservoir:empty_op()
  return rtransition(self, 'empty')
end


local ErrorTransitions = Scalar.kind {
  name = 'flow.error',
  transitions = {
    set = { mode = 'update', order = 0, step = function(_old, p) return p.err or Errors.FLOW_ERROR, true end },
    get = { mode = 'select', order = 100, step = function(err) if err == nil then return nil end; return err, err end },
  },
}

local function error_op(scalar)
  return scalar:transition_op(ErrorTransitions:transition('get'))
end
local function set_error_op(scalar, err)
  return scalar:transition_op(ErrorTransitions:transition('set'), { err = err })
end

local EndpointTransitions = Scalar.kind {
  name = 'flow.endpoint',
  transitions = {
    check_open = {
      mode = 'update',
      order = 100,
      step = function(open, payload)
        if open == true then return true, true end
        return open, false, payload.err or Errors.CLOSED
      end,
    },
    close = {
      mode = 'update',
      order = 0,
      step = function(_open) return false, true end,
    },
  },
}

local function expect_open(scalar, err)
  return scalar:transition_op(EndpointTransitions:transition('check_open'), { err = err or Errors.CLOSED })
end


local function denied_values(kind)
  if kind == 'count' then return Op.always(0, nil, Errors.UNAUTHORISED) end
  if kind == 'bool' then return Op.always(false, Errors.UNAUTHORISED) end
  return Op.always(nil, Errors.UNAUTHORISED)
end

local function authority_target(handle)
  local flow = handle and handle.flow or handle
  if handle and handle.owner and handle.owner._fibers_scope_owner then return handle end
  if flow and flow.owner and flow.owner._fibers_scope_owner then return flow end
  return nil
end

local function live_or_retired_op(handle, right, body, denied_kind)
  if type(right) == 'function' then body, right, denied_kind = right, nil, body end
  local op_scope = Runtime.current_scope and Runtime.current_scope() or nil
  local flow = handle and handle.flow or handle
  if (handle and handle._fibers_retired) or (flow and flow._fibers_retired) then
    return Op.always(nil, Errors.RETIRED)
  end
  local owner = (handle and handle.owner) or (flow and flow.owner)
  local item = owner and (handle and handle.owner and handle or flow)
  local function after_live()
    local target = authority_target(handle)
    if not target then return body() end
    local scope = op_scope
    if not scope or type(scope.authorise_op) ~= 'function' then return denied_values(denied_kind) end
    return scope:authorise_op(target, right or 'use'):map(function()
      return true
    end):or_else(Op.always(false)):and_then(function(ok)
      if not ok then return denied_values(denied_kind) end
      return body()
    end)
  end
  if owner and type(owner.live_op) == 'function' and item then
    return owner:live_op(item):and_then(function(live)
      if live then return after_live() end
      return Op.always(nil, Errors.RETIRED)
    end)
  end
  return after_live()
end

function Inlet:write_op(bytes)
  bytes = as_bytes(bytes)
  if bytes == '' then return Op.always(0) end
  return live_or_retired_op(self, 'write', function()
    return self.flow.output_error:read_op():and_then(function(err)
      if err then return Op.always(nil, err) end
      return Op.tensor({
        expect_open(self.flow.input_open, Errors.CLOSED),
        expect_open(self.flow.output_open, Errors.BROKEN_PIPE),
      }):and_then(function(gates)
        if gates[1][1] ~= true then return Op.always(nil, gates[1][2]) end
        if gates[2][1] ~= true then return Op.always(nil, gates[2][2]) end
        return self.flow.reservoir:append_op(bytes):map(function(ok, n_or_err)
          if ok then return n_or_err end
          return nil, n_or_err
        end)
      end)
    end)
  end)
end

function Inlet:append_op(bytes) return self:write_op(bytes) end
function Inlet:append_some_op(bytes) return self:write_some_op(bytes) end
function Inlet:write_some_op(bytes)
  bytes = as_bytes(bytes)
  return live_or_retired_op(self, 'write', function()
    return Op.tensor({
      expect_open(self.flow.input_open, Errors.CLOSED),
      expect_open(self.flow.output_open, Errors.BROKEN_PIPE),
    }):and_then(function(gates)
      if gates[1][1] ~= true then return Op.always(0, bytes, gates[1][2]) end
      if gates[2][1] ~= true then return Op.always(0, bytes, gates[2][2]) end
      return self.flow.reservoir:append_some_op(bytes)
    end)
  end)
end
function Inlet:close_op(_reason) return self.flow.input_open:transition_op(EndpointTransitions:transition('close')) end
function Inlet:closed_op() return self.flow.input_open:expect_op(false) end
function Inlet:error_op() return error_op(self.flow.input_error) end
function Inlet:fail_op(reason) return Op.tensor({ set_error_op(self.flow.input_error, reason or Errors.READ_ERROR), self:close_op(reason) }):map(function() return true end) end
function Inlet:flush_op() return self.flow.reservoir:settled_error_op():and_then(function(err) return Op.always(nil, err) end):or_else(self.flow:drained_op()) end
function Inlet:drain_op() return self.flow:drained_op() end
function Inlet:drained_op() return self.flow:drained_op() end
function Inlet:shutdown_op(reason) return self:close_op(reason) end
function Inlet:exit_op() return self.flow:closed_op() end

function Outlet:read_some_op(n)
  n = as_nonneg_int(n, 1, 'flow read size')
  if n == 0 then return Op.always('') end
  return live_or_retired_op(self, 'read', function()
    return self.flow.input_error:read_op():and_then(function(err)
      if err then return Op.always(nil, err) end
      return self.flow.reservoir:read_some_op(n):or_else(
        self.flow.input_open:expect_op(false):and_then(function() return Op.always(nil, Errors.EOF) end)
      )
    end)
  end)
end
function Outlet:read_op(n) return self:read_some_op(n) end
function Outlet:read_exactly_op(n)
  n = as_nonneg_int(n, 0, 'flow exact read size')
  if n == 0 then return Op.always('') end
  return live_or_retired_op(self, 'read', function()
    return self.flow.reservoir:read_exactly_op(n):or_else(
      self.flow.input_open:expect_op(false):and_then(function()
        return self.flow.reservoir:drain_available_op():map(function(partial) return nil, Errors.EOF, partial end)
      end)
    )
  end)
end
function Outlet:peek_op(n) return live_or_retired_op(self, 'read', function() return self.flow.reservoir:peek_op(n) end) end
function Outlet:peek_some_op(n) return self:peek_op(n) end
function Outlet:read_until_op(sep, opts)
  opts = opts or {}
  return live_or_retired_op(self, 'read', function()
    return self.flow.reservoir:read_until_op(sep, opts):or_else(
      self.flow.input_open:expect_op(false):and_then(function()
        return self.flow.reservoir:drain_available_op():map(function(partial)
          if partial == '' then return nil, Errors.EOF end
          return nil, Errors.EOF, partial
        end)
      end)
    )
  end)
end
function Outlet:read_including_op(sep, opts)
  opts = opts or {}; opts.include = true
  return self:read_until_op(sep, opts)
end
function Outlet:read_line_op(opts)
  opts = opts or {}
  local sep = opts.sep or opts.terminator or '\n'
  return live_or_retired_op(self, 'read', function()
    return self.flow.reservoir:read_until_op(sep, { limit = opts.limit, err = Errors.LINE_TOO_LONG }):or_else(
      self.flow.input_open:expect_op(false):and_then(function()
        return self.flow.reservoir:drain_available_op():map(function(partial)
          if partial == '' then return nil, Errors.EOF end
          return partial
        end)
      end)
    )
  end)
end
function Outlet:drop_op(n)
  return self:read_exactly_op(n):map(function(bytes) return #(bytes or '') end)
end
function Outlet:splice_to(inlet, n)
  n = as_nonneg_int(n, 0, 'flow splice size')
  return self:peek_op(n):and_then(function(bytes)
    return inlet:write_op(bytes):and_then(function(written, err)
      if not written then
        if err == Errors.CAPACITY then err = Errors.TOO_LARGE end
        return Op.always(nil, err)
      end
      return self:drop_op(n)
    end)
  end)
end
function Outlet:read_all_op(opts)
  opts = opts or {}
  if opts.unlimited ~= true and opts.max == nil then error('read_all_op expects opts.max or opts.unlimited = true', 2) end
  if opts.max ~= nil then opts.max = as_nonneg_int(opts.max, nil, 'flow read_all max') end
  return live_or_retired_op(self, 'read', function()
    return self.flow.reservoir:read_all_too_large_op(opts):or_else(
      self.flow.input_open:expect_op(false):and_then(function()
        return self.flow.reservoir:read_all_limited_op(opts)
      end)
    )
  end)
end
function Outlet:lease_op(n, owner, meta)
  return live_or_retired_op(self, 'read', function()
    return self.flow.reservoir:lease_op(n, owner, meta)
  end)
end
function Outlet:lease_some_op(n, owner, meta) return self:lease_op(n, owner, meta):or_else(self.flow.input_open:expect_op(false):and_then(function() return Op.always(nil, Errors.CLOSED_AND_DRAINED) end)) end
function Outlet:ack_lease_op(lease, n) return self.flow.reservoir:ack_lease_op(lease, n) end
function Outlet:return_lease_op(lease) return self.flow.reservoir:return_lease_op(lease) end
function Outlet:fail_write_op(err) err = err or Errors.WRITE_ERROR; return Op.tensor({ set_error_op(self.flow.output_error, err), self:close_op(err), self.flow.reservoir:settle_op(err) }):map(function() return false, err end) end
function Outlet:close_op(_reason) return self.flow.output_open:transition_op(EndpointTransitions:transition('close')) end
function Outlet:closed_op() return self.flow.output_open:expect_op(false) end
function Outlet:error_op() return error_op(self.flow.output_error) end
function Outlet:shutdown_op(reason) local settle = reason or Errors.BROKEN_PIPE; return Op.tensor({ self:close_op(reason), set_error_op(self.flow.output_error, Errors.BROKEN_PIPE), self.flow.reservoir:settle_op(settle) }):map(function() return true end) end
function Outlet:exit_op() return self.flow:closed_op() end

function Flow.new(opts)
  opts = opts or {}
  next_id = next_id + 1
  local name = opts.name or ('flow-' .. tostring(next_id))
  local self = Ownership.handle(name, { kind = 'flow' })
  setmetatable(self, Flow)
  self.input_open = Scalar.new(true, name .. ':input-open')
  self.output_open = Scalar.new(true, name .. ':output-open')
  self.input_error = Scalar.new(nil, name .. ':input-error')
  self.output_error = Scalar.new(nil, name .. ':output-error')
  self.reservoir = Reservoir.new(self, opts)
  self._fibers_settle = require('fibers.internal.settlement').flow()
  self.input = Ownership.handle(name .. ':inlet', { kind = 'flow_inlet', flow = self })
  setmetatable(self.input, Inlet)
  self.output = Ownership.handle(name .. ':outlet', { kind = 'flow_outlet', flow = self })
  setmetatable(self.output, Outlet)
  return self
end

function Flow:inlet() return self.input end
function Flow:outlet() return self.output end
function Flow:inspect_op()
  return Op.all({ self.input_open:read_op(), self.output_open:read_op(), self.reservoir:inspect_op() }):map(function(rows)
    local r = rows[3][1]
    r.input_open = rows[1][1]
    r.output_open = rows[2][1]
    return r
  end)
end
function Flow:close_op(reason) return Op.tensor({ self.input:close_op(reason), self.output:close_op(reason) }):map(function() return true end) end
function Flow:shutdown_op(reason) return self:close_op(reason) end
function Flow:closed_op() return Op.all({ self.input:closed_op(), self.output:closed_op() }):map(function() return true end) end
function Flow:exit_op() return self:closed_op() end
function Flow:drained_op() return self.reservoir:empty_op() end

Flow.Inlet = Inlet
Flow.Outlet = Outlet
Flow.Reservoir = Reservoir
Flow.Lease = Lease
Flow.Errors = Errors
return Flow
