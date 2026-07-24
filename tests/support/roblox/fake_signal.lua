local FakeSignal = {}
FakeSignal.__index = FakeSignal

function FakeSignal.new(name, opts)
  opts = opts or {}
  return setmetatable({
    name = name or 'signal',
    handlers = {},
    disconnect_failures = opts.disconnect_failures or 0,
  }, FakeSignal)
end

function FakeSignal:Connect(fn)
  local signal = self
  local record = { fn = fn, connected = true }
  self.handlers[#self.handlers + 1] = record
  local connection = { Connected = true }
  function connection:Disconnect()
    if signal.disconnect_failures > 0 then
      signal.disconnect_failures = signal.disconnect_failures - 1
      error('fake disconnect failure')
    end
    record.connected = false
    self.Connected = false
  end
  return connection
end

function FakeSignal:Fire(...)
  for i = 1, #self.handlers do
    local record = self.handlers[i]
    if record.connected then
      record.fn(...)
    end
  end
end

function FakeSignal:connection_count()
  local count = 0
  for i = 1, #self.handlers do
    if self.handlers[i].connected then
      count = count + 1
    end
  end
  return count
end

return FakeSignal
