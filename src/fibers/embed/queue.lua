---A re-entry-safe external delivery queue for embedded Fibers runtimes.
---
---Host callbacks enqueue authorised deliveries and request a later driver turn.
---The queue is drained only from `Application:advance`, while the Runtime is at
---its external-driver boundary.

local Queue = {}
Queue.__index = Queue

local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function default_now()
  return os and type(os.clock) == 'function' and os.clock() or 0
end

function Queue.new(opts)
  opts = opts or {}
  local now = opts.now or default_now
  local self = setmetatable({
    kind = opts.kind or 'embedded',
    name = opts.name or opts.kind or 'embedded',
    family = opts.family or opts.kind or 'embedded',
    capabilities = opts.capabilities or { time = true, external = true },
    _now = now,
    _queue = {},
    _queue_head = 1,
    _queue_tail = 0,
    _wake_pending = false,
    _wake_reason = nil,
    _wake_callback = nil,
    _done = false,
    _done_value = nil,
    _closed = false,
    on_external_error = opts.on_external_error,
    on_done = opts.on_done,
  }, Queue)
  self.now = function()
    return now()
  end
  return self
end

function Queue:set_wake_callback(callback)
  if callback ~= nil and type(callback) ~= 'function' then
    error('embedded wake callback must be a function or nil', 2)
  end
  self._wake_callback = callback
  if callback and self._wake_pending and not self._closed and not self._done then
    callback(self._wake_reason or 'external')
  end
  return self
end

function Queue:has_pending_wake()
  return self._wake_pending == true
end

function Queue:consume_wake(fallback)
  local reason = self._wake_reason or fallback or 'external'
  self._wake_pending = false
  self._wake_reason = nil
  return reason
end

function Queue:has_external()
  return self._queue_head <= self._queue_tail
end

function Queue:enqueue(fn, ...)
  if self._closed or self._done then
    return false, 'host-closed'
  end
  if type(fn) ~= 'function' then
    error('embedded Queue:enqueue expects a function', 2)
  end
  self._queue_tail = self._queue_tail + 1
  self._queue[self._queue_tail] = { fn = fn, args = pack(...) }
  self:wake('external')
  return true
end

function Queue:deliver(feed, ...)
  local args = pack(...)
  return self:enqueue(function()
    feed:set(unpack_(args, 1, args.n))
  end)
end

function Queue:clear(feed, ...)
  local args = pack(...)
  return self:enqueue(function()
    feed:clear(unpack_(args, 1, args.n))
  end)
end

function Queue:_drain_external(limit)
  local count = 0
  while self._queue_head <= self._queue_tail and (not limit or count < limit) do
    local index = self._queue_head
    local item = self._queue[index]
    self._queue[index] = nil
    self._queue_head = index + 1
    if item then
      count = count + 1
      local ok, err = pcall(item.fn, unpack_(item.args, 1, item.args.n))
      if not ok then
        if self.on_external_error then
          self.on_external_error(err)
        end
        error(err, 0)
      end
    end
  end
  if self._queue_head > self._queue_tail then
    self._queue_head, self._queue_tail = 1, 0
  end
  return count
end

function Queue:wake(reason)
  if self._closed or self._done then
    return false
  end
  local already_pending = self._wake_pending
  self._wake_pending = true
  self._wake_reason = self._wake_reason or reason or 'external'
  local callback = self._wake_callback
  if callback and not already_pending then
    local ok, err = pcall(callback, self._wake_reason)
    if not ok then
      if self.on_external_error then
        self.on_external_error(err)
      else
        error(err, 0)
      end
    end
  end
  return true
end

function Queue:mark_done(value)
  if self._done then return value end
  self._done = true
  self._done_value = value
  if type(self.on_done) == 'function' then
    self.on_done(value)
  end
  return value
end

function Queue:supports_interest(interest)
  local kind = interest and interest.external_kind
  local capability = kind and self.capabilities and self.capabilities[kind]
  if capability == false then
    return false, 'unsupported-' .. tostring(kind)
  end
  return true
end

function Queue:block()
  return nil, 'embedded-host-does-not-block'
end

function Queue:close()
  if self._closed then return true end
  self._closed = true
  self._wake_callback = nil
  self._queue = {}
  self._queue_head, self._queue_tail = 1, 0
  return true
end

return Queue
