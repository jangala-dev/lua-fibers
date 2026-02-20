-- fibers/io/wait_fd.lua
--
-- Minimal Pulse-only fd readiness ticket.
-- Semantics: becomes ready once the poller has observed an event for (fd, dir)
-- after the watch is armed. The caller should treat readiness as a prompt to
-- retry the non-blocking syscall (spurious wakes are permitted).

local runtime = require 'fibers.runtime'
local op      = require 'fibers.op'

local function wait_fd_op(fd, dir)
  if fd == nil then error('wait_fd_op: fd must be non-nil', 2) end
  if dir ~= 'rd' and dir ~= 'wr' then
    error('wait_fd_op: dir must be "rd" or "wr"', 2)
  end

  return op.new_primitive(
    -- poll(self, ctx, out) -> ready:boolean
    function (self, ctx, out)
      if self.done then
        if out then out.n = 0 end
        return true
      end

      -- Single-fibre use.
      if self.waker and self.waker ~= ctx.waker then
        error('wait_fd ticket used from a different fibre', 0)
      end
      self.waker = ctx.waker

      -- Arm once. The returned handle is expected to carry `fired` (boolean).
      if not self.handle then
        self.handle = runtime.poller_watch(self.fd, self.dir, self.waker)
      end

      local h = self.handle
      if h and h.fired then
        if out then out.n = 0 end
        return true
      end

      return false
    end,

    -- commit(self, ctx) -> (no results)
    function (self, _)
      if self.done then return end
      self.done = true

      if self.handle then
        runtime.poller_cancel(self.handle)
        self.handle = nil
      end

      self.waker = nil
      return
    end,

    -- rollback(self, ctx, why)
    function (self, _, _)
      if self.done then return end

      if self.handle then
        runtime.poller_cancel(self.handle)
        self.handle = nil
      end

      self.waker = nil
    end,

    -- state
    { done = false, fd = fd, dir = dir, handle = nil, waker = nil }
  )
end

local function wait_readable_op(fd) return wait_fd_op(fd, 'rd') end
local function wait_writable_op(fd) return wait_fd_op(fd, 'wr') end

return {
  wait_fd_op       = wait_fd_op,
  wait_readable_op = wait_readable_op,
  wait_writable_op = wait_writable_op,
}
