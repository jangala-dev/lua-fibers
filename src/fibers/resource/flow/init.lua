-- Transactional byte flow resource.
--
-- Flow is the atomic transfer resource used to assemble Streams and custom
-- transfer structures.  Its transition machine, leases and committed change
-- effect live together because they have no independent consumers.

local Op = require('fibers.op')
local Scalar = require('fibers.resource.scalar')
local Rope = require('fibers.resource.flow.rope')
local Errors = require('fibers.resource.flow.errors')
local Effect = require('fibers.effect')
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')

local Lease = {}
Lease.__index = Lease

function Lease.new(flow, id, holder, bytes, opts)
  opts = opts or {}
  return setmetatable({
    flow = flow,
    id = id,
    holder = holder,
    _bytes = bytes or '',
    _length = #(bytes or ''),
    meta = opts.meta,
    _fibers_flow_lease = true,
  }, Lease)
end

function Lease.is(value)
  return getmetatable(value) == Lease or type(value) == 'table' and value._fibers_flow_lease == true
end
function Lease:bytes()
  return self._bytes or ''
end
function Lease:length()
  return self._length or #(self._bytes or '')
end
function Lease:inspect()
  return { id = self.id, bytes = self:bytes(), length = self:length(), holder = self.holder, flow = self.flow }
end
function Lease:ack_op(n)
  return self.flow:_ack_lease_op(self, n)
end
function Lease:release_op()
  return self.flow:_return_lease_op(self)
end
function Lease:fail_op(err)
  return self.flow:_fail_lease_op(self, err)
end

local SpaceLease = {}
SpaceLease.__index = SpaceLease

function SpaceLease.new(flow, id, holder, capacity, opts)
  opts = opts or {}
  return setmetatable({
    flow = flow,
    id = id,
    holder = holder,
    _capacity = capacity or 0,
    meta = opts.meta,
    _fibers_flow_space_lease = true,
  }, SpaceLease)
end

function SpaceLease.is(value)
  return getmetatable(value) == SpaceLease
    or type(value) == 'table' and value._fibers_flow_space_lease == true
end
function SpaceLease:capacity()
  return self._capacity or 0
end
function SpaceLease:inspect()
  return { id = self.id, capacity = self:capacity(), holder = self.holder, flow = self.flow, meta = self.meta }
end
function SpaceLease:commit_op(bytes)
  return self.flow:_commit_space_op(self, bytes)
end
function SpaceLease:release_op()
  return self.flow:_release_space_op(self)
end
function SpaceLease:fail_op(err)
  return self.flow:_fail_space_op(self, err)
end

local FlowChangedKind

local function flow_key(payload)
  local flow = payload.flow
  return flow and flow._fibers_id or tostring(flow)
end

FlowChangedKind = Effect.kind({
  name = 'flow_changed',
  key = flow_key,
  merge = function(a, _b)
    return a
  end,
  validate_payload = function(_kind, payload)
    if type(payload.flow) ~= 'table' or payload.flow._fibers_id == nil then
      return nil,
        {
          kind = 'invalid_effect_payload',
          message = 'flow_changed effect requires a Flow',
        }
    end
    return true
  end,
  prepare = function(_rt, payload)
    return {
      kind = FlowChangedKind,
      key = flow_key(payload),
      payload = payload,
      discharge = function(rt, prepared)
        local reactor = rt.host_reactor
        if reactor and type(reactor._notify_flow_changed) == 'function' then
          reactor:_notify_flow_changed(prepared.payload.flow)
        end
        return true
      end,
    }
  end,
})

local FlowEffect = {}

function FlowEffect.changed(flow)
  return Effect.of(FlowChangedKind, { flow = flow })
end

FlowEffect.Kind = FlowChangedKind

local Machine = {}
local INF = math.huge
local Ready = Scalar.Ready
local Wait = Scalar.Wait

local function new_state()
  return {
    input_open = true,
    output_open = true,
    input_error = nil,
    output_error = nil,
    rope = Rope.new(),
    lease_id = nil,
    lease_holder = nil,
    lease_bytes = nil,
    lease_meta = nil,
    next_lease = 0,
    space_id = nil,
    space_holder = nil,
    space_capacity = 0,
    space_meta = nil,
    next_space = 0,
    settled_error = nil,
    settled_version = 0,
  }
end

local function copy_state(s, clone_rope)
  s = s or new_state()
  return {
    input_open = s.input_open ~= false,
    output_open = s.output_open ~= false,
    input_error = s.input_error,
    output_error = s.output_error,
    rope = clone_rope and (Rope.is(s.rope) and s.rope:clone() or Rope.new()) or (s.rope or Rope.new()),
    lease_id = s.lease_id,
    lease_holder = s.lease_holder,
    lease_bytes = s.lease_bytes,
    lease_meta = s.lease_meta,
    next_lease = s.next_lease or 0,
    space_id = s.space_id,
    space_holder = s.space_holder,
    space_capacity = s.space_capacity or 0,
    space_meta = s.space_meta,
    next_space = s.next_space or 0,
    settled_error = s.settled_error,
    settled_version = s.settled_version or 0,
  }
end
local function clone_state(s)
  return copy_state(s, true)
end
local function copy_metadata_state(s)
  return copy_state(s, false)
end

local function leased_length(s)
  return #(s and s.lease_bytes or '')
end
local function reserved_length(s)
  return s and (s.space_capacity or 0) or 0
end
local function retained_length(s)
  return (s.rope and s.rope:length() or 0) + leased_length(s) + reserved_length(s)
end
local function free_for_capacity(capacity, s)
  if not capacity then
    return INF
  end
  return capacity - retained_length(s)
end
local function inspect_state(self, s)
  s = s or new_state()
  local queued = s.rope:length()
  local leased = leased_length(s)
  local reserved = reserved_length(s)
  local retained = queued + leased + reserved
  local cap = self.capacity or INF
  return {
    queued = queued,
    queued_length = queued,
    leased = leased,
    retained = retained,
    reserved = reserved,
    capacity = self.capacity,
    free = cap == INF and INF or cap - retained,
    leases = s.lease_id and 1 or 0,
    space_leases = s.space_id and 1 or 0,
    chunk_count = s.rope:chunk_count(),
    data = s.rope:tostring(),
    input_open = s.input_open ~= false,
    output_open = s.output_open ~= false,
    settled_error = s.settled_error,
    settled_version = s.settled_version or 0,
  }
end
local function lease_handle(flow, s)
  return Lease.new(flow, s.lease_id, s.lease_holder, s.lease_bytes or '', { meta = s.lease_meta })
end
local function clear_lease(s)
  s.lease_id, s.lease_holder, s.lease_bytes, s.lease_meta = nil, nil, nil, nil
end
local function space_lease_handle(flow, s)
  return SpaceLease.new(flow, s.space_id, s.space_holder, s.space_capacity or 0, { meta = s.space_meta })
end
local function clear_space_lease(s)
  s.space_id, s.space_holder, s.space_capacity, s.space_meta = nil, nil, 0, nil
end
local function close_endpoint(s, endpoint)
  s[endpoint .. '_open'] = false
end
local function fail_endpoint(s, endpoint, err)
  s[endpoint .. '_error'] = err
  close_endpoint(s, endpoint)
end
local function clear_retained(s)
  s.rope = Rope.new()
  clear_lease(s)
  clear_space_lease(s)
end
local function close_flow(s)
  close_endpoint(s, 'input')
  close_endpoint(s, 'output')
  clear_retained(s)
end
local function record_settled_error(s, err)
  s.settled_error = err
  s.settled_version = (s.settled_version or 0) + 1
end

local function find_until(s, sep)
  local pos = s.rope:find(sep)
  return pos and (pos + #sep) or nil, pos
end
local function committed_input_closed(flow)
  local state = flow and flow.state and flow.state.value
  return state and state.input_open == false
end

local function transition(mode, supplies, order, spec)
  spec.mode = mode
  spec.accepts_supply = true
  spec.supplies = supplies
  spec.order = order
  return spec
end

local FlowTransitions = Scalar.kind({
  name = 'flow.v3',
  transitions = {
    write = transition('select', 'any', 100, {
      ready = function(s, p)
        local bytes = p.bytes or ''
        if s.output_error or not s.input_open or not s.output_open then
          return true
        end
        if p.capacity and #bytes > p.capacity then
          return true
        end
        return #bytes <= free_for_capacity(p.capacity, s)
      end,
      step = function(s, p)
        local bytes = p.bytes or ''
        if s.output_error then
          return Ready.same(nil, s.output_error)
        end
        if not s.input_open then
          return Ready.same(nil, Errors.CLOSED)
        end
        if not s.output_open then
          return Ready.same(nil, Errors.BROKEN_PIPE)
        end
        if p.capacity and #bytes > p.capacity then
          return Ready.same(nil, Errors.CAPACITY)
        end
        if #bytes > free_for_capacity(p.capacity, s) then
          return Wait
        end
        local next_s = clone_state(s)
        next_s.rope:append(bytes)
        return Ready.write(next_s, #bytes)
      end,
    }),
    write_some = transition('update', 'any', 100, {
      step = function(s, p)
        local bytes = p.bytes or ''
        if s.output_error then
          return Ready.same(nil, bytes, s.output_error)
        end
        if not s.input_open then
          return Ready.same(nil, bytes, Errors.CLOSED)
        end
        if not s.output_open then
          return Ready.same(nil, bytes, Errors.BROKEN_PIPE)
        end
        local free = free_for_capacity(p.capacity, s)
        if free <= 0 or #bytes == 0 then
          return Ready.same(0, bytes)
        end
        local n = math.min(#bytes, free)
        local next_s = clone_state(s)
        next_s.rope:append(bytes:sub(1, n))
        return Ready.write(next_s, n, bytes:sub(n + 1))
      end,
    }),
    read_some = transition('select', 'any', 50, {
      ready = function(s, p)
        return s.input_error ~= nil or s.rope:length() > 0 or committed_input_closed(p.flow)
      end,
      step = function(s, p)
        if s.input_error then
          return Ready.same(nil, s.input_error)
        end
        local queued = s.rope:length()
        if queued > 0 then
          local next_s = clone_state(s)
          return Ready.write(next_s, next_s.rope:take(math.min(p.n, queued)))
        end
        if committed_input_closed(p.flow) then
          return Ready.same(nil, Errors.EOF)
        end
        return Wait
      end,
    }),
    read_exactly = transition('select', 'any', 50, {
      ready = function(s, p)
        return s.input_error ~= nil or s.rope:length() >= p.n or committed_input_closed(p.flow)
      end,
      step = function(s, p)
        if s.input_error then
          return Ready.same(nil, s.input_error)
        end
        local queued = s.rope:length()
        if queued >= p.n then
          local next_s = clone_state(s)
          return Ready.write(next_s, next_s.rope:take(p.n))
        end
        if committed_input_closed(p.flow) then
          if queued > 0 then
            local next_s = clone_state(s)
            local partial = next_s.rope:take(queued)
            return Ready.write(next_s, nil, Errors.EOF, partial)
          end
          return Ready.same(nil, Errors.EOF, '')
        end
        return Wait
      end,
    }),
    read_until = transition('select', 'any', 50, {
      ready = function(s, p)
        if s.input_error then
          return true
        end
        local end_pos = find_until(s, p.sep)
        if end_pos then
          return true
        end
        if p.limit and s.rope:length() > p.limit then
          return not s.rope:ends_with_prefix(p.sep)
        end
        return false
      end,
      step = function(s, p)
        if s.input_error then
          return Ready.same(nil, s.input_error)
        end
        local end_pos, data_len = find_until(s, p.sep)
        if end_pos then
          if p.limit and data_len > p.limit then
            return Ready.same(nil, (p.err or Errors.TOO_LARGE))
          end
          local next_s = clone_state(s)
          local out = next_s.rope:take(end_pos)
          if p.include then
            return Ready.write(next_s, out)
          end
          return Ready.write(next_s, out:sub(1, #out - #p.sep))
        end
        if p.limit and s.rope:length() > p.limit then
          if not s.rope:ends_with_prefix(p.sep) then
            return Ready.same(nil, (p.err or Errors.TOO_LARGE))
          end
        end
        return Wait
      end,
    }),
    read_until_or_eof = transition('select', 'any', 50, {
      ready = function(s, p)
        if s.input_error then
          return true
        end
        local end_pos = find_until(s, p.sep)
        if end_pos then
          return true
        end
        if p.limit and s.rope:length() > p.limit then
          if not s.rope:ends_with_prefix(p.sep) then
            return true
          end
        end
        return committed_input_closed(p.flow)
      end,
      step = function(s, p)
        if s.input_error then
          return Ready.same(nil, s.input_error)
        end
        local end_pos, data_len = find_until(s, p.sep)
        if end_pos then
          if p.limit and data_len > p.limit then
            return Ready.same(nil, (p.err or Errors.TOO_LARGE))
          end
          local next_s = clone_state(s)
          local out = next_s.rope:take(end_pos)
          if p.include then
            return Ready.write(next_s, out)
          end
          return Ready.write(next_s, out:sub(1, #out - #p.sep))
        end
        if p.limit and s.rope:length() > p.limit then
          if not s.rope:ends_with_prefix(p.sep) then
            return Ready.same(nil, (p.err or Errors.TOO_LARGE))
          end
        end
        if committed_input_closed(p.flow) then
          local queued = s.rope:length()
          if queued > 0 then
            local next_s = clone_state(s)
            local partial = next_s.rope:take(queued)
            if p.line_mode then
              return Ready.write(next_s, partial)
            end
            return Ready.write(next_s, nil, Errors.EOF, partial)
          end
          return Ready.same(nil, Errors.EOF)
        end
        return Wait
      end,
    }),
    drain_available = transition('update', 'any', 100, {
      step = function(s)
        local len = s.rope:length()
        if len == 0 then
          return Ready.same('')
        end
        local next_s = clone_state(s)
        local data = next_s.rope:take(len)
        return Ready.write(next_s, data)
      end,
    }),
    drain_all_limited = transition('update', 'any', 100, {
      step = function(s, p)
        local len = s.rope:length()
        if not p.unlimited and p.max and len > p.max then
          return Ready.same(nil, Errors.TOO_LARGE)
        end
        if len == 0 then
          return Ready.same('')
        end
        local next_s = clone_state(s)
        local data = next_s.rope:take(len)
        return Ready.write(next_s, data)
      end,
    }),
    read_all_too_large = transition('query', 'none', 90, {
      step = function(s, p)
        if p.unlimited or not p.max or s.rope:length() <= p.max then
          return Wait
        end
        return Ready.same(Errors.TOO_LARGE)
      end,
    }),
    lease = transition('select', 'any', 50, {
      ready = function(s, p)
        if s.lease_id then
          return true
        end
        return not s.rope:is_empty() or committed_input_closed(p.flow)
      end,
      step = function(s, p)
        if s.lease_id then
          if p.holder ~= nil and s.lease_holder == p.holder then
            return Ready.same(lease_handle(p.flow, s))
          end
          return Ready.same(nil, Errors.LEASE_ALREADY_ACTIVE)
        end
        if s.rope:is_empty() then
          if committed_input_closed(p.flow) then
            return Ready.same(nil, Errors.CLOSED_AND_DRAINED)
          end
          return Wait
        end
        local next_s = clone_state(s)
        local bytes = next_s.rope:take(math.min(p.n, next_s.rope:length()))
        next_s.next_lease = (next_s.next_lease or 0) + 1
        next_s.lease_id = (p.flow_id or 'flow') .. ':lease:' .. tostring(next_s.next_lease)
        next_s.lease_holder = p.holder
        next_s.lease_bytes = bytes
        next_s.lease_meta = p.meta
        return Ready.write(next_s, lease_handle(p.flow, next_s))
      end,
    }),
    ack_lease = transition('update', 'any', 0, {
      step = function(s, p)
        if not s.lease_id or s.lease_id ~= p.lease.id then
          return Ready.same(false, Errors.NO_LEASE)
        end
        if p.n > #(s.lease_bytes or '') then
          return Ready.same(false, Errors.LEASE_ACK_TOO_LARGE)
        end
        if p.n == 0 then
          return Ready.same(true, 0)
        end
        local next_s = copy_metadata_state(s)
        next_s.lease_bytes = (next_s.lease_bytes or ''):sub(p.n + 1)
        if next_s.lease_bytes == '' then
          clear_lease(next_s)
        end
        return Ready.write(next_s, true, p.n)
      end,
    }),
    return_lease = transition('update', 'any', 0, {
      step = function(s, p)
        if not s.lease_id or s.lease_id ~= p.lease.id then
          return Ready.same(false, Errors.NO_LEASE)
        end
        local bytes = s.lease_bytes or ''
        if bytes == '' then
          local next_s = copy_metadata_state(s)
          clear_lease(next_s)
          return Ready.write(next_s, true, 0)
        end
        local next_s = clone_state(s)
        next_s.rope:prepend(bytes)
        clear_lease(next_s)
        return Ready.write(next_s, true, #bytes)
      end,
    }),
    fail_lease = transition('update', 'any', 0, {
      step = function(s, p)
        if not s.lease_id or s.lease_id ~= p.lease.id then
          return Ready.same(false, Errors.NO_LEASE)
        end
        local next_s = copy_metadata_state(s)
        local n = #(next_s.lease_bytes or '')
        clear_lease(next_s)
        record_settled_error(next_s, p.err or Errors.FLOW_ERROR)
        return Ready.write(next_s, true, n)
      end,
    }),
    drop_exactly = transition('select', 'any', 50, {
      ready = function(s, p)
        return s.input_error ~= nil or s.rope:length() >= p.n or committed_input_closed(p.flow)
      end,
      step = function(s, p)
        if s.input_error then
          return Ready.same(nil, s.input_error)
        end
        local queued = s.rope:length()
        if queued >= p.n then
          if p.n == 0 then
            return Ready.same(0)
          end
          local next_s = clone_state(s)
          next_s.rope:take(p.n)
          return Ready.write(next_s, p.n)
        end
        if committed_input_closed(p.flow) then
          if queued > 0 then
            local next_s = clone_state(s)
            next_s.rope:take(queued)
            return Ready.write(next_s, nil, Errors.EOF, queued)
          end
          return Ready.same(nil, Errors.EOF, 0)
        end
        return Wait
      end,
    }),
    reserve_space = transition('select', 'any', 90, {
      ready = function(s, p)
        if s.output_error or not s.input_open or not s.output_open then
          return true
        end
        if s.space_id then
          return true
        end
        return free_for_capacity(p.capacity, s) > 0
      end,
      step = function(s, p)
        if s.output_error then
          return Ready.same(nil, s.output_error)
        end
        if not s.input_open then
          return Ready.same(nil, Errors.CLOSED)
        end
        if not s.output_open then
          return Ready.same(nil, Errors.BROKEN_PIPE)
        end
        if s.space_id then
          if p.holder ~= nil and s.space_holder == p.holder then
            return Ready.same(space_lease_handle(p.flow, s))
          end
          return Ready.same(nil, Errors.SPACE_LEASE_ALREADY_ACTIVE)
        end
        local free = free_for_capacity(p.capacity, s)
        if free <= 0 then
          return Wait
        end
        local next_s = copy_metadata_state(s)
        next_s.next_space = (next_s.next_space or 0) + 1
        next_s.space_id = (p.flow_id or 'flow') .. ':space:' .. tostring(next_s.next_space)
        next_s.space_holder = p.holder
        next_s.space_capacity = math.min(p.n, free)
        next_s.space_meta = p.meta
        return Ready.write(next_s, space_lease_handle(p.flow, next_s))
      end,
    }),
    commit_space = transition('update', 'any', 0, {
      step = function(s, p)
        if not s.space_id or s.space_id ~= p.lease.id then
          return Ready.same(nil, Errors.NO_SPACE_LEASE)
        end
        local bytes = p.bytes or ''
        if #bytes > (s.space_capacity or 0) then
          return Ready.same(nil, Errors.SPACE_COMMIT_TOO_LARGE)
        end
        local next_s = clone_state(s)
        clear_space_lease(next_s)
        if bytes ~= '' then
          next_s.rope:append(bytes)
        end
        return Ready.write(next_s, #bytes)
      end,
    }),
    release_space = transition('update', 'any', 0, {
      step = function(s, p)
        if not s.space_id or s.space_id ~= p.lease.id then
          return Ready.same(false, Errors.NO_SPACE_LEASE)
        end
        local n = s.space_capacity or 0
        local next_s = copy_metadata_state(s)
        clear_space_lease(next_s)
        return Ready.write(next_s, true, n)
      end,
    }),
    fail_space = transition('update', 'any', 0, {
      step = function(s, p)
        if not s.space_id or s.space_id ~= p.lease.id then
          return Ready.same(false, Errors.NO_SPACE_LEASE)
        end
        local next_s = copy_metadata_state(s)
        clear_space_lease(next_s)
        fail_endpoint(next_s, 'input', p.err or Errors.READ_ERROR)
        return Ready.write(next_s, true)
      end,
    }),
    capacity_some = transition('query', 'none', 90, {
      validate = function(p)
        if p.n == nil or p.n <= 0 then
          error('flow capacity count must be positive', 2)
        end
      end,
      step = function(s, p)
        local free = free_for_capacity(p.capacity, s)
        if free <= 0 then
          return Wait
        end
        return Ready.same(math.min(p.n, free))
      end,
    }),
    peek = transition('query', 'none', 100, {
      step = function(s, p)
        if s.rope:length() < p.n then
          return Wait
        end
        return Ready.same(s.rope:peek(p.n))
      end,
    }),
    flush = transition('query', 'none', 100, {
      step = function(s)
        if s.settled_error then
          return Ready.same(nil, s.settled_error)
        end
        if retained_length(s) == 0 then
          return Ready.same(true)
        end
        return Wait
      end,
    }),
    settled_error = transition('query', 'none', 100, {
      step = function(s)
        if not s.settled_error then
          return Wait
        end
        return Ready.same(s.settled_error)
      end,
    }),
    settle = transition('update', 'any', 0, {
      step = function(s, p)
        local retained = retained_length(s)
        local next_s = copy_metadata_state(s)
        close_flow(next_s)
        if retained > 0 then
          record_settled_error(next_s, p.err or Errors.FLOW_ERROR)
        end
        if retained == 0 and s.input_open == false and s.output_open == false then
          return Ready.same(true)
        end
        return Ready.write(next_s, true)
      end,
    }),
    shutdown_flow = transition('update', 'any', 0, {
      step = function(s, p)
        local retained = retained_length(s)
        local already_terminal = s.input_open == false and s.output_open == false and retained == 0
        if already_terminal then
          return Ready.same(true)
        end
        local next_s = copy_metadata_state(s)
        close_flow(next_s)
        if retained > 0 and p.settle_error ~= nil then
          record_settled_error(next_s, p.settle_error)
        end
        return Ready.write(next_s, true)
      end,
    }),
    closed = transition('query', 'none', 100, {
      step = function(s)
        if s.input_open == false and s.output_open == false and retained_length(s) == 0 then
          if s.settled_error then
            return Ready.same(nil, s.settled_error)
          end
          return Ready.same(true)
        end
        return Wait
      end,
    }),
    empty = transition('query', 'none', 100, {
      step = function(s)
        if retained_length(s) ~= 0 then
          return Wait
        end
        return Ready.same(true)
      end,
    }),
    close_input = transition('update', 'any', 0, {
      step = function(s)
        if s.input_open == false then
          return Ready.same(true)
        end
        local next_s = copy_metadata_state(s)
        close_endpoint(next_s, 'input')
        return Ready.write(next_s, true)
      end,
    }),
    close_output = transition('update', 'any', 0, {
      step = function(s)
        if s.output_open == false then
          return Ready.same(true)
        end
        local next_s = copy_metadata_state(s)
        close_endpoint(next_s, 'output')
        return Ready.write(next_s, true)
      end,
    }),
    input_closed = transition('query', 'none', 100, {
      step = function(_s, p)
        if committed_input_closed(p.flow) then
          return Ready.same(true)
        end
        return Wait
      end,
    }),
    output_closed = transition('query', 'none', 100, {
      step = function(_s, p)
        local committed = p.flow and p.flow.state and p.flow.state.value
        if committed and committed.output_open == false then
          return Ready.same(true)
        end
        return Wait
      end,
    }),
    set_input_error = transition('update', 'any', 0, {
      step = function(s, p)
        local next_s = copy_metadata_state(s)
        fail_endpoint(next_s, 'input', p.err or Errors.READ_ERROR)
        return Ready.write(next_s, true)
      end,
    }),
    set_output_error = transition('update', 'any', 0, {
      step = function(s, p)
        local next_s = copy_metadata_state(s)
        fail_endpoint(next_s, 'output', p.err or Errors.WRITE_ERROR)
        return Ready.write(next_s, true)
      end,
    }),
    input_error = transition('query', 'none', 100, {
      step = function(s)
        if s.input_error == nil then
          return Wait
        end
        return Ready.same(s.input_error)
      end,
    }),
    output_error = transition('query', 'none', 100, {
      step = function(s)
        if s.output_error == nil then
          return Wait
        end
        return Ready.same(s.output_error)
      end,
    }),
    fail_write = transition('update', 'any', 0, {
      step = function(s, p)
        local err = p.err or Errors.WRITE_ERROR
        local next_s = copy_metadata_state(s)
        fail_endpoint(next_s, 'output', err)
        local retained = retained_length(s)
        clear_retained(next_s)
        if retained > 0 then
          record_settled_error(next_s, err)
        end
        return Ready.write(next_s, false, err)
      end,
    }),
    shutdown_output = transition('update', 'any', 0, {
      step = function(s, p)
        local err = p.err or Errors.BROKEN_PIPE
        local next_s = copy_metadata_state(s)
        fail_endpoint(next_s, 'output', s.output_error or Errors.BROKEN_PIPE)
        local retained = retained_length(s)
        clear_retained(next_s)
        if retained > 0 then
          record_settled_error(next_s, err)
        end
        return Ready.write(next_s, true)
      end,
    }),
  },
})

local function transition_op(flow, name, payload)
  payload = payload or {}
  payload.capacity = flow.capacity
  payload.flow = flow
  payload.flow_id = flow._fibers_id
  local transition = FlowTransitions:transition(name)
  local option = flow.state:transition_op(transition, payload)
  if transition.mode == 'query' then
    return option
  end
  return option:and_then(function(...)
    local values = Op._pack(...)
    return Op.emit(FlowEffect.changed(flow)):map(function()
      return Op._unpack(values, 1, values.n)
    end)
  end)
end

Machine.new_state = new_state
Machine.inspect = inspect_state
Machine.free = free_for_capacity
Machine.transition_op = transition_op

local Flow = {}
Flow.__index = Flow

local Inlet = {}
Inlet.__index = Inlet
local Outlet = {}
Outlet.__index = Outlet

local next_id = 0
local function validate_options(opts, allowed, label)
  for key in pairs(opts or {}) do
    if not allowed[key] then
      error((label or 'options') .. ' does not accept ' .. tostring(key), 3)
    end
  end
end

local function as_bytes(bytes)
  if type(bytes) ~= 'string' then
    error('flow bytes must be a string', 3)
  end
  return bytes
end
local function as_nonneg_int(n, default, label)
  if n == nil then
    n = default
  end
  if type(n) ~= 'number' or n ~= n or n < 0 or n ~= math.floor(n) then
    error((label or 'flow byte count') .. ' must be a non-negative integer', 3)
  end
  return n
end
local function as_pos_int(n, default, label)
  n = as_nonneg_int(n, default, label)
  if n <= 0 then
    error((label or 'flow byte count') .. ' must be positive', 3)
  end
  return n
end
local function as_capacity(n)
  if n == nil then
    return nil
  end
  return as_nonneg_int(n, nil, 'flow capacity')
end

local new_state = Machine.new_state
local inspect_state = Machine.inspect
local free_for_capacity = Machine.free
local transition_op = Machine.transition_op

local function live_or_retired_op(handle, body)
  local life = Lifetime.of(handle)
  local phase = life and life:current_state().closure_phase or nil
  if phase == 'closed' or phase == 'closure_failed' then
    return Op.always(nil, Errors.RETIRED)
  end
  return body()
end

function Inlet:write_op(bytes)
  bytes = as_bytes(bytes)
  if bytes == '' then
    return Op.always(0)
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'write', { bytes = bytes })
  end)
end

function Inlet:write_some_op(bytes)
  bytes = as_bytes(bytes)
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'write_some', { bytes = bytes })
  end)
end

function Inlet:reserve_some_op(n, holder, meta)
  return live_or_retired_op(self, function()
    n = as_pos_int(n, 1, 'flow space reservation size')
    return transition_op(self.flow, 'reserve_space', { n = n, holder = holder, meta = meta })
  end)
end

function Inlet:flush_op()
  return transition_op(self.flow, 'flush')
end

function Inlet:close_op(_reason)
  return transition_op(self.flow, 'close_input')
end

function Inlet:closed_op()
  return transition_op(self.flow, 'input_closed')
end

function Inlet:fail_op(reason)
  return transition_op(self.flow, 'set_input_error', { err = reason or Errors.READ_ERROR })
end

function Outlet:read_some_op(n)
  n = as_nonneg_int(n, 1, 'flow read size')
  if n == 0 then
    return Op.always('')
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_some', { n = n })
  end)
end

function Outlet:read_exactly_op(n)
  n = as_nonneg_int(n, 0, 'flow exact read size')
  if n == 0 then
    return Op.always('')
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_exactly', { n = n })
  end)
end

function Outlet:peek_exactly_op(n)
  return live_or_retired_op(self, function()
    n = as_nonneg_int(n, 1, 'flow peek size')
    if n == 0 then
      return Op.always('')
    end
    return transition_op(self.flow, 'peek', { n = n })
  end)
end

function Outlet:read_until_op(separator, opts)
  opts = opts or {}
  validate_options(opts, { include = true, max = true }, 'read_until_op options')
  if type(separator) ~= 'string' or separator == '' then
    error('flow read_until separator must be a non-empty string', 2)
  end
  local max = opts.max
  if max == nil then
    max = 8192
  end
  max = as_nonneg_int(max, nil, 'flow read_until max')
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_until_or_eof', {
      sep = separator,
      limit = max,
      include = opts.include == true,
      err = Errors.TOO_LARGE,
    })
  end)
end

function Outlet:read_line_op(opts)
  opts = opts or {}
  validate_options(opts, { terminator = true, keep_terminator = true, max = true }, 'read_line_op options')
  local terminator = opts.terminator or '\n'
  if type(terminator) ~= 'string' or terminator == '' then
    error('flow line terminator must be a non-empty string', 2)
  end
  local max = opts.max
  if max == nil then
    max = 8192
  end
  max = as_nonneg_int(max, nil, 'flow line max')
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_until_or_eof', {
      sep = terminator,
      limit = max,
      include = opts.keep_terminator == true,
      err = Errors.LINE_TOO_LONG,
      line_mode = true,
    })
  end)
end

function Outlet:read_all_op(opts)
  opts = opts or {}
  validate_options(opts, { max = true }, 'read_all_op options')
  if opts.max == nil then
    error('read_all_op expects opts.max', 2)
  end
  local max = as_nonneg_int(opts.max, nil, 'flow read_all max')
  local read_opts = { max = max, unlimited = false }
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'read_all_too_large', read_opts)
      :and_then(function(err)
        return Op.always(nil, err)
      end)
      :or_else(transition_op(self.flow, 'input_closed'):and_then(function()
        return transition_op(self.flow, 'drain_all_limited', read_opts)
      end))
  end)
end

function Outlet:drop_op(n)
  n = as_nonneg_int(n, 0, 'flow drop size')
  if n == 0 then
    return Op.always(0)
  end
  return live_or_retired_op(self, function()
    return transition_op(self.flow, 'drop_exactly', { n = n })
  end)
end

function Outlet:splice_to_op(inlet, n)
  n = as_nonneg_int(n, 0, 'flow splice size')
  return self:peek_exactly_op(n):and_then(function(bytes)
    return inlet:write_op(bytes):and_then(function(written, err)
      if not written then
        if err == Errors.CAPACITY then
          err = Errors.TOO_LARGE
        end
        return Op.always(nil, err)
      end
      return self:drop_op(n)
    end)
  end)
end

function Outlet:lease_some_op(n, holder, meta)
  return live_or_retired_op(self, function()
    n = as_pos_int(n, 1, 'flow lease size')
    return transition_op(self.flow, 'lease', { n = n, holder = holder, meta = meta })
  end)
end

function Outlet:close_op(reason)
  return transition_op(self.flow, 'shutdown_output', { err = reason or Errors.CLOSED })
end

function Outlet:closed_op()
  return transition_op(self.flow, 'output_closed')
end

function Outlet:fail_op(err)
  return transition_op(self.flow, 'fail_write', { err = err or Errors.WRITE_ERROR })
end

function Flow:_ack_lease_op(lease, n)
  if not Lease.is(lease) then
    error('ack_lease_op expects a flow lease', 2)
  end
  n = as_nonneg_int(n, lease:length(), 'flow lease ack count')
  return transition_op(self, 'ack_lease', { lease = lease, n = n })
end
function Flow:_return_lease_op(lease)
  if not Lease.is(lease) then
    error('return_lease_op expects a flow lease', 2)
  end
  return transition_op(self, 'return_lease', { lease = lease })
end
function Flow:_fail_lease_op(lease, err)
  if not Lease.is(lease) then
    error('fail_lease_op expects a flow lease', 2)
  end
  return transition_op(self, 'fail_lease', { lease = lease, err = err })
end
function Flow:_commit_space_op(lease, bytes)
  if not SpaceLease.is(lease) then
    error('commit_space_op expects a flow space lease', 2)
  end
  return transition_op(self, 'commit_space', { lease = lease, bytes = as_bytes(bytes) })
end
function Flow:_release_space_op(lease)
  if not SpaceLease.is(lease) then
    error('release_space_op expects a flow space lease', 2)
  end
  return transition_op(self, 'release_space', { lease = lease })
end
function Flow:_fail_space_op(lease, err)
  if not SpaceLease.is(lease) then
    error('fail_space_op expects a flow space lease', 2)
  end
  return transition_op(self, 'fail_space', { lease = lease, err = err })
end

function Flow.new(opts)
  opts = opts or {}
  validate_options(opts, { name = true, capacity = true }, 'Flow.new options')
  next_id = next_id + 1
  local name = opts.name or ('flow-' .. tostring(next_id))
  local self = setmetatable({
    name = name,
    _fibers_id = name,
    capacity = as_capacity(opts.capacity),
    state = Scalar.machine(new_state(), name .. ':state'),
  }, Flow)
  self.input = setmetatable({ name = name .. ':inlet', flow = self }, Inlet)
  self.output = setmetatable({ name = name .. ':outlet', flow = self }, Outlet)
  Lifetime.define(self.input, {
    role = 'flow_inlet',
    rights = { write = true, use = true },
    closure = Closure.request_then_wait(function(_ctx, record)
      return record.item:close_op()
    end, function(_ctx, record)
      return record.item:closed_op()
    end, { name = 'flow_inlet', finish_result = Closure.require_ok('flow inlet closure failed') }),
  })
  Lifetime.define(self.output, {
    role = 'flow_outlet',
    rights = { read = true, use = true },
    closure = Closure.request_then_wait(function(_ctx, record)
      return record.item:close_op()
    end, function(_ctx, record)
      return record.item:closed_op()
    end, { name = 'flow_outlet', finish_result = Closure.require_ok('flow outlet closure failed') }),
  })
  return self
end

function Flow:_read_serviceable()
  local state = self.state.value
  if not state or state.input_error or state.output_error then
    return false
  end
  if state.input_open == false or state.output_open == false or state.space_id then
    return false
  end
  return free_for_capacity(self.capacity, state) > 0
end

function Flow:_write_serviceable()
  local state = self.state.value
  if not state or state.output_error or state.output_open == false then
    return false
  end
  if state.lease_id then
    return true
  end
  return not state.rope:is_empty()
end

function Flow:_read_terminal_reason()
  local state = self.state.value
  if not state then
    return nil
  end
  if state.output_open == false then
    return 'reader_closed'
  end
  if state.input_error then
    return state.input_error
  end
  if state.output_error then
    return state.output_error
  end
  if state.input_open == false then
    return Errors.EOF
  end
  return nil
end

function Flow:_write_terminal_reason(draining)
  local state = self.state.value
  if not state then
    return nil
  end
  if state.output_error then
    return state.output_error
  end
  if state.output_open == false then
    return Errors.BROKEN_PIPE
  end
  if state.input_error then
    return state.input_error
  end
  if state.input_open == false and not state.lease_id and state.rope:is_empty() then
    return draining and Errors.CLOSED_AND_DRAINED or Errors.CLOSED
  end
  return nil
end

function Flow:inlet()
  return self.input
end

function Flow:outlet()
  return self.output
end

function Flow:inspect_op()
  return self.state:read_op():map(function(s)
    return inspect_state(self, s)
  end)
end

function Flow:abort_op(_reason)
  return transition_op(self, 'shutdown_flow')
end

function Flow:closed_op()
  return transition_op(self, 'closed')
end

Flow.Error = {
  EOF = Errors.EOF,
  CLOSED = Errors.CLOSED,
  BROKEN_PIPE = Errors.BROKEN_PIPE,
  TOO_LARGE = Errors.TOO_LARGE,
  LINE_TOO_LONG = Errors.LINE_TOO_LONG,
  RETIRED = Errors.RETIRED,
}

return Flow
