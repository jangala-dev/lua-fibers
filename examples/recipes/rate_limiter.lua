-- Token-bucket rate limiter built on typed Machine transitions.
--
-- The limiter is deliberately a scalar state-machine facility.  Refill and
-- token consumption happen in named transitions, avoiding double-refill races.

local Op = require('fibers.op')
local StateMachine = require('fibers.resource.machine')
local Ready = StateMachine.Ready
local Clock = require('fibers.resource.clock')

local RateLimiter = {}
RateLimiter.__index = RateLimiter

local function finite_number(x, name)
  if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then
    error(name .. ' must be a finite number', 3)
  end
  return x
end

local function copy_state(s)
  return { tokens = s.tokens or 0, last = s.last or 0 }
end

local function refill_state(self, state, now)
  state = copy_state(state or {})
  now = finite_number(now, 'rate limiter time')
  local elapsed = now - (state.last or 0)
  if elapsed < 0 then
    elapsed = 0
  end
  local tokens = (state.tokens or 0) + elapsed * self.rate
  if tokens > self.capacity then
    tokens = self.capacity
  end
  return { tokens = tokens, last = now }
end

local function normalise_amount(self, n)
  n = n or 1
  finite_number(n, 'rate limiter amount')
  if n <= 0 then
    error('rate limiter amount must be positive', 3)
  end
  if n > self.capacity then
    error('rate limiter amount exceeds capacity', 3)
  end
  return n
end

local Refill = StateMachine.update('rate_limiter.refill', function(state, payload, ctx)
  local next_state = refill_state(payload, state, ctx:now())
  return Ready.write(next_state, next_state.tokens, next_state.last)
end)

local TryAcquire = StateMachine.update(
  'rate_limiter.try_acquire',
  function(state, payload, ctx)
    local now = ctx:now()
    local next_state = refill_state(payload, state, now)
    local n = payload.n
    if next_state.tokens >= n then
      next_state = { tokens = next_state.tokens - n, last = next_state.last }
      return Ready.write(next_state, true, nil, next_state.tokens)
    end
    local needed = n - next_state.tokens
    local deadline = now + needed / payload.rate
    return Ready.write(next_state, false, deadline, next_state.tokens)
  end,
  nil,
  function(payload)
    finite_number(payload.n, 'rate limiter amount')
    if payload.n <= 0 then
      error('rate limiter amount must be positive', 3)
    end
    if payload.n > payload.capacity then
      error('rate limiter amount exceeds capacity', 3)
    end
  end
)

local function bucket_payload(self, extra)
  local p = { capacity = self.capacity, rate = self.rate }
  for k, v in pairs(extra or {}) do
    p[k] = v
  end
  return p
end

function RateLimiter.new(opts)
  opts = opts or {}
  local capacity = finite_number(opts.capacity or 1, 'rate limiter capacity')
  if capacity <= 0 then
    error('rate limiter capacity must be positive', 2)
  end
  local rate = finite_number(opts.rate or opts.per_second or 1, 'rate limiter rate')
  if rate <= 0 then
    error('rate limiter rate must be positive', 2)
  end
  local initial = opts.initial
  if initial == nil then
    initial = capacity
  end
  initial = finite_number(initial, 'rate limiter initial')
  if initial < 0 then
    initial = 0
  end
  if initial > capacity then
    initial = capacity
  end
  local last = finite_number(opts.last or opts.initial_time or 0, 'rate limiter initial time')
  local name = opts.name or 'rate-limiter'
  local self = setmetatable({
    name = name,
    capacity = capacity,
    rate = rate,
    clock = opts.clock or Clock.new(name .. ':clock'),
  }, RateLimiter)
  self.state = StateMachine.new({ tokens = initial, last = last }, name .. ':state')
  return self
end

function RateLimiter:refill_op()
  return self.state:transition_op(Refill, bucket_payload(self))
end

function RateLimiter:try_acquire_op(n)
  n = normalise_amount(self, n)
  return self.state:transition_op(TryAcquire, bucket_payload(self, { n = n }))
end

function RateLimiter:acquire_op(n)
  n = normalise_amount(self, n)
  return self:try_acquire_op(n):and_then(function(ok, deadline)
    if ok then
      return Op.always(true)
    end
    return self.clock:at_op(deadline):and_then(function()
      return self:acquire_op(n)
    end)
  end)
end

function RateLimiter:state_op()
  return Op.guard(function(activation)
    local now = activation:now()
    return self.state:read_op():map(function(state)
      local s = refill_state(self, state, now)
      return { tokens = s.tokens, last = s.last, capacity = self.capacity, rate = self.rate }
    end)
  end)
end

function RateLimiter:available_op()
  return self:state_op():map(function(state)
    return state.tokens
  end)
end

return RateLimiter
