-- fibers/pulse.lua
--
-- Per-fibre waker: one waiter, with a pending latch. Wakes by enqueuing.

local Pulse = {}
Pulse.__index = Pulse

function Pulse.new(sched)
  if not sched then error('Pulse.new requires a scheduler', 2) end
  return setmetatable({ sched = sched, waiter = nil, pending = false }, Pulse)
end

function Pulse:signal()
  local fib = self.waiter
  if not fib then
    self.pending = true
    return
  end

  fib._waiting_pulse = nil
  self.waiter = nil
  self.sched:schedule(fib)
end

function Pulse:subscribe(fib)
  if fib._waiting_pulse == self then
    return
  end

  if fib._waiting_pulse ~= nil then
    error('fibre attempted to wait on two pulses', 0)
  end

  if self.pending then
    self.pending = false
    self.sched:schedule(fib)
    return
  end

  fib._waiting_pulse = self
  self.waiter = fib
end

return {
  Pulse = Pulse,
  new = Pulse.new,
}
