-- Closeable mailbox from Channel + private reference counting + Cell + Counter.

local Channel = require('fibers.channel')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')
local Completion = require('fibers.resource.completion')

local Mailbox = {}
local Tx = {}
local Rx = {}

Tx.__index = Tx
Rx.__index = Rx

local function tx(mailbox, active)
  return setmetatable({ _mailbox = mailbox, _active = Cell.new(active ~= false) }, Tx)
end

local function active_op(sender, active) return sender._active:expect_op(active) end

local function true_() return true end

local function reason_op(mailbox) return mailbox._reason:value_op() end

local function remember_reason_op(mailbox, reason)
  if reason == nil then return Op.always(true) end
  return mailbox._reason:publish_success_op(reason):map(true_)
end

local function drop_op(mailbox)
  return mailbox._dropped:bump_op()
end

local function block(mailbox, value)
  return mailbox._messages:put_op(value)
end

local function reject_newest(mailbox, value)
  return mailbox._messages:put_op(value):or_else(drop_op(mailbox):map(function()
    return false, 'full'
  end))
end

local function drop_oldest(mailbox, value)
  local put = mailbox._messages:put_op(value)
  local replace = Op.together({ mailbox._messages:get_op(), put, drop_op(mailbox) }):map(true_)
  return put:or_else(replace)
end

local function new_mailbox(capacity, accept)
  capacity = capacity or 0
  local mailbox = Label.attach(Label.identity({
    _accept = accept,
    _messages = Channel.new(capacity),
    _senders = Counter.new(1),
    _reason = Completion.new(),
    _dropped = Counter.new(0),
  }, 'mailbox'))
  Label.child(mailbox._messages, mailbox, 'messages')
  Label.child(mailbox._senders, mailbox, 'senders')
  Label.child(mailbox._reason, mailbox, 'reason')
  Label.child(mailbox._dropped, mailbox, 'dropped')

  return tx(mailbox, true), setmetatable({ _mailbox = mailbox }, Rx)
end

function Mailbox.new(capacity)
  return new_mailbox(capacity, block)
end

function Mailbox.reject_newest(capacity)
  return new_mailbox(capacity, reject_newest)
end

function Mailbox.drop_oldest(capacity)
  capacity = capacity or 0
  if capacity == 0 then
    return Mailbox.reject_newest(0)
  end
  return new_mailbox(capacity, drop_oldest)
end

function Tx:send_op(value)
  if value == nil then
    error('mailbox send_op does not accept nil payloads', 2)
  end

  local mailbox = self._mailbox
  local put = mailbox._accept(mailbox, value)
  local send = active_op(self, true):and_then(put)

  local inactive = active_op(self, false):and_then(reason_op(mailbox):map(function(reason)
      return nil, reason
    end))

  return send:or_else(inactive)
end

function Tx:clone_op()
  local mailbox = self._mailbox
  return Op.guard(function()
    local active_clone = tx(mailbox, true)
    local inactive_clone = tx(mailbox, false)
    local clone = active_op(self, true):and_then(mailbox._senders:give_op(1)):map(function()
      return active_clone
    end)
    return clone:or_else(active_op(self, false):map(function() return inactive_clone end))
  end)
end

function Tx:close_op(reason)
  local mailbox = self._mailbox
  local close = active_op(self, true):and_then(Op.each(
    self._active:write_op(false), mailbox._senders:take_op(1)
  ):map(true_)):or_else(active_op(self, false):map(function() return false end))
  return close:and_then(Op.guard(function(closed)
    return closed and remember_reason_op(mailbox, reason) or Op.always(true)
  end))
end

function Rx:recv_op()
  local mailbox = self._mailbox
  local closed = mailbox._senders:zero_op():and_then(reason_op(mailbox):map(function(reason)
      return nil, reason
    end))
  return mailbox._messages:get_op():or_else(closed)
end

local function why_op(self) return reason_op(self._mailbox) end
local function dropped_op(self) return self._mailbox._dropped:read_op() end

local function endpoint_label(self, ...)
  local mailbox = self._mailbox
  if select('#', ...) == 0 then return Label.get(mailbox) end
  Label.set(mailbox, select(1, ...), 2)
  return self
end

Tx.label, Rx.label = endpoint_label, endpoint_label
Tx.why_op, Rx.why_op = why_op, why_op
Tx.dropped_op, Rx.dropped_op = dropped_op, dropped_op

Mailbox.Tx = Tx
Mailbox.Rx = Rx

Direct.install(Tx, { 'why', 'dropped', 'send', 'clone', 'close' })
Direct.install(Rx, { 'why', 'dropped', 'recv' })

return Mailbox
