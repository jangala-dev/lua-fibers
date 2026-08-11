---A re-entry-safe external delivery queue for embedded Fibers runtimes.
---
---Host callbacks enqueue authorised deliveries and request a later driver turn.
---The queue is drained only from `Application:advance`, while the Runtime is at
---its external-driver boundary.

local Base = require('fibers.internal.host.base')
local Label = require('fibers.internal.label')
local Contract = require('fibers.internal.contract')

local Queue = {}
Queue.__index = Queue
setmetatable(Queue, { __index = Base })

local unpack_ = table.unpack or unpack
local next_queue = 0

local function default_now()
  return os and type(os.clock) == 'function' and os.clock() or 0
end

local QUEUE_OPTIONS = {
  now = Contract.func,
  kind = Contract.non_empty_string,
  family = Contract.non_empty_string,
  features = Contract.table,
  on_external_error = Contract.func,
  on_done = Contract.func,
  label = Contract.non_empty_string,
}

local function close_queue(self)
  self._wake_callback = nil
  self._queue_head, self._queue_tail = nil, nil
  return true
end

function Queue.new(opts)
  opts = Contract.record(opts, QUEUE_OPTIONS, 'Queue.new options', 2)
  local now = opts.now or default_now
  next_queue = next_queue + 1
  local self = Label.attach(setmetatable({
    _fibers_id = 'embedded-host-' .. tostring(next_queue),
    kind = opts.kind or 'embedded', family = opts.family or opts.kind or 'embedded',
    _now = now,
    _on_external_error = opts.on_external_error,
    _on_done = opts.on_done,
  }, Queue), opts.label)
  Base.init(self, opts.features or { time = true, external = true }, close_queue)
  self.now = function() return now() end
  return self
end

function Queue:set_wake_callback(callback)
  if callback ~= nil and type(callback) ~= 'function' then
    error('embedded wake callback must be a function or nil', 2)
  end
  self._wake_callback = callback
  if callback and self._wake_reason ~= nil and not self._closed and not self._done then
    callback(self._wake_reason)
  end
  return self
end

function Queue:_has_pending_wake()
  return self._wake_reason ~= nil
end

function Queue:_consume_wake(fallback)
  local reason = self._wake_reason or fallback or 'external'
  self._wake_reason = nil
  return reason
end

function Queue:_has_external()
  return self._queue_head ~= nil
end

function Queue:enqueue(fn, ...)
  if self._closed or self._done then
    return false, 'host-closed'
  end
  if type(fn) ~= 'function' then
    error('embedded Queue:enqueue expects a function', 2)
  end
  local item = { fn = fn, n = select('#', ...), ... }
  if self._queue_tail then self._queue_tail.next = item else self._queue_head = item end
  self._queue_tail = item
  self:wake('external')
  return true
end

function Queue:deliver(feed, ...)
  return self:enqueue(feed.set, feed, ...)
end

function Queue:clear(feed, ...)
  return self:enqueue(feed.clear, feed, ...)
end

function Queue:_drain_external(limit)
  local count = 0
  while self._queue_head and (not limit or count < limit) do
    local item = self._queue_head
    self._queue_head = item.next
    item.next = nil
    if not self._queue_head then self._queue_tail = nil end
    count = count + 1
    local ok, err = pcall(item.fn, unpack_(item, 1, item.n))
    if not ok then
      if self._on_external_error then self._on_external_error(err) end
      error(err, 0)
    end
  end
  return count
end

function Queue:wake(reason)
  if self._closed or self._done then
    return false
  end
  local already_pending = self._wake_reason ~= nil
  self._wake_reason = self._wake_reason or reason or 'external'
  local callback = self._wake_callback
  if callback and not already_pending then
    local ok, err = pcall(callback, self._wake_reason)
    if not ok then
      if self._on_external_error then
        self._on_external_error(err)
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
  if type(self._on_done) == 'function' then
    self._on_done(value)
  end
  return value
end

function Queue:supports_interest(interest)
  local kind = interest and interest.external_kind
  local capability = kind and self:feature(kind)
  if capability == false then
    return false, 'unsupported-' .. tostring(kind)
  end
  return true
end

function Queue:block()
  return nil, 'embedded-host-does-not-block'
end


return Queue
