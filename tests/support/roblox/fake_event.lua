local FakeEvent = {}
FakeEvent.__index = FakeEvent

local unpack_ = table.unpack or unpack
local Protected = require('fibers.internal.protected')

local function pack(...)
  return { n = select('#', ...), ... }
end

function FakeEvent.new(scheduler, name)
  local self = setmetatable({
    scheduler = scheduler,
    name = name or 'event',
    waiters = {},
    handlers = {},
    destroyed = false,
    fire_count = 0,
  }, FakeEvent)

  self.Event = {
    Wait = function()
      if self.destroyed then
        error('event is destroyed', 2)
      end
      local co = Protected.running(coroutine.running())
      if not co then
        error('Event:Wait requires a coroutine', 2)
      end
      self.waiters[#self.waiters + 1] = co
      return coroutine.yield()
    end,
    Connect = function(_, fn)
      local record = { fn = fn, connected = true }
      self.handlers[#self.handlers + 1] = record
      return {
        Connected = true,
        Disconnect = function(connection)
          record.connected = false
          connection.Connected = false
        end,
      }
    end,
  }

  return self
end

function FakeEvent:Fire(...)
  if self.destroyed then
    return
  end
  self.fire_count = self.fire_count + 1
  local args = pack(...)
  local waiters = self.waiters
  self.waiters = {}
  for i = 1, #waiters do
    self.scheduler:resume(waiters[i], unpack_(args, 1, args.n))
  end
  for i = 1, #self.handlers do
    local handler = self.handlers[i]
    if handler.connected then
      self.scheduler.api.defer(handler.fn, unpack_(args, 1, args.n))
    end
  end
end

function FakeEvent:Destroy()
  self.destroyed = true
  self.waiters = {}
  self.handlers = {}
end

return FakeEvent
