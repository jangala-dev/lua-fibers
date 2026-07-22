-- Versioned broadcast pulse built on typed Scalar transitions.
--
-- A Pulse is a coalescing notifier.  Signals increment a logical version;
-- waiters observe that the version has advanced, or that the pulse has been
-- closed.  It is a facility over Scalar, not a scheduler-side wait list.

local Scalar = require('fibers.scalar')
local Ready, Wait = Scalar.Ready, Scalar.Wait
local Op = require('fibers.op')
local perform = require('fibers.perform')

local Pulse = {}
Pulse.__index = Pulse

local next_id = 0

local function non_negative_integer(n, name, level)
  if type(n) ~= 'number' or n < 0 or n ~= math.floor(n) then
    error(name .. ' must be a non-negative integer', level or 3)
  end
  return n
end

local function copy_state(st)
  st = st or {}
  return {
    version = st.version or 0,
    closed = st.closed == true,
    reason = st.reason,
  }
end

local State = Scalar.kind({
  name = 'pulse.state',
  transitions = {
    signal = {
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 0,
      step = function(st)
        st = copy_state(st)
        if st.closed then
          return Ready.write(st, nil)
        end
        st.version = st.version + 1
        return Ready.write(st, st.version)
      end,
    },
    close = {
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 10,
      step = function(st, payload)
        st = copy_state(st)
        if st.reason == nil and payload.reason ~= nil then
          st.reason = payload.reason
        end
        st.closed = true
        return Ready.write(st, true)
      end,
    },
    changed = {
      mode = 'select',
      accepts_supply = true,
      supplies = 'any',
      order = 100,
      validate = function(payload)
        non_negative_integer(payload.last_seen, 'pulse changed last_seen', 3)
      end,
      step = function(st, payload)
        st = copy_state(st)
        if st.version > payload.last_seen then
          return Ready.write(st, st.version, nil)
        end
        if st.closed then
          return Ready.write(st, nil, st.reason)
        end
        return Wait
      end,
    },
  },
})

function Pulse.new(opts, name)
  opts = opts or {}
  if type(opts) == 'number' then
    opts = { initial_version = opts }
  end
  next_id = next_id + 1
  local id = 'pulse-' .. tostring(next_id)
  local pname = opts.name or name or id
  local initial = opts.initial_version
  if initial == nil then
    initial = opts.version or 0
  end
  non_negative_integer(initial, 'pulse initial_version', 2)
  return setmetatable({
    name = pname,
    state = opts.state or Scalar.new({ version = initial, closed = false, reason = nil }, pname .. ':state'),
  }, Pulse)
end

function Pulse:snapshot_op()
  return self.state:read_op():map(function(st)
    return copy_state(st)
  end)
end

function Pulse:version_op()
  return self.state:read_op():map(function(st)
    return (st and st.version) or 0
  end)
end

function Pulse:why_op()
  return self.state:read_op():map(function(st)
    return st and st.reason or nil
  end)
end

function Pulse:is_closed_op()
  return self.state:read_op():map(function(st)
    return st and st.closed == true or false
  end)
end

function Pulse:signal_op()
  return Op.guard(function()
    return self.state:read_op():and_then(function(st)
      st = copy_state(st)
      if st.closed then
        return Op.always(nil)
      end
      return self.state:transition_op(State:transition('signal'))
    end)
  end)
end

function Pulse:close_op(reason)
  return self.state:transition_op(State:transition('close'), { reason = reason })
end

function Pulse:changed_op(last_seen)
  return self.state:transition_op(State:transition('changed'), { last_seen = last_seen })
end

function Pulse:next_op()
  return Op.guard(function()
    return self.state:read_op():and_then(function(st)
      return self:changed_op((st and st.version) or 0)
    end)
  end)
end

Pulse.State = State
function Pulse:signal()
  return perform(self:signal_op())
end

function Pulse:close(reason)
  return perform(self:close_op(reason))
end

function Pulse:changed(last_seen)
  return perform(self:changed_op(last_seen))
end

function Pulse:next()
  return perform(self:next_op())
end

return Pulse
