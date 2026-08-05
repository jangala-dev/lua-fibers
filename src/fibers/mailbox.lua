-- Closeable mailbox from Channel + RefCount + Cell + Counter.

local Channel = require('fibers.channel')
local RefCount = require('fibers.resource.ref_count')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local Op = require('fibers.op')
local Direct = require('fibers.internal.direct')
local Label = require('fibers.internal.label')

local Mailbox = {}
local Tx = {}
local Rx = {}

Mailbox.__index = Mailbox
Tx.__index = Tx
Rx.__index = Rx

local NO_REASON = {}
local next_id = 0

local function tx(mailbox, handle)
  return setmetatable({ _mailbox = mailbox, _handle = handle }, Tx)
end

local function reason_op(mailbox)
  return mailbox._reason:read_op():map(function(reason)
    return reason ~= NO_REASON and reason or nil
  end)
end

local function remember_reason_op(mailbox, reason)
  if reason == nil then return Op.always(true) end

  local remember = mailbox._reason:expect_op(NO_REASON):and_then(mailbox._reason:write_op(reason))

  return remember:or_else(mailbox._reason:wait_until_op(function(value)
    return value ~= NO_REASON
  end):map(function()
    return true
  end))
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
  local replace = Op.together({
    mailbox._messages:get_op(),
    mailbox._messages:put_op(value),
    drop_op(mailbox),
  }):map(function()
    return true
  end)
  return put:or_else(replace)
end

local function new_mailbox(capacity, accept, full)
  capacity = capacity or 0
  if type(capacity) ~= 'number' or capacity < 0 or capacity % 1 ~= 0 then
    error('mailbox capacity must be a non-negative integer', 3)
  end

  next_id = next_id + 1
  local refs, first = RefCount.new()
  local id = 'mailbox-' .. tostring(next_id)
  local mailbox = Label.attach(setmetatable({
    _fibers_id = id,
    name = id,
    capacity = capacity,
    full = full,
    _accept = accept,
    _messages = Channel.new(capacity),
    _senders = refs,
    _reason = Cell.new(NO_REASON),
    _dropped = Counter.new(0),
  }, Mailbox))
  Label.child(mailbox._messages, mailbox, 'messages')
  Label.child(mailbox._senders, mailbox, 'senders')
  Label.child(mailbox._reason, mailbox, 'reason')
  Label.child(mailbox._dropped, mailbox, 'dropped')

  return tx(mailbox, first), setmetatable({ _mailbox = mailbox }, Rx)
end

function Mailbox.new(capacity)
  return new_mailbox(capacity, block, 'block')
end

function Mailbox.reject_newest(capacity)
  return new_mailbox(capacity, reject_newest, 'reject_newest')
end

function Mailbox.drop_oldest(capacity)
  capacity = capacity or 0
  if capacity == 0 then
    return Mailbox.reject_newest(0)
  end
  return new_mailbox(capacity, drop_oldest, 'drop_oldest')
end

function Tx:send_op(value)
  if value == nil then
    error('mailbox send_op does not accept nil payloads', 2)
  end

  local mailbox = self._mailbox
  local put = mailbox._accept(mailbox, value)
  local send = self._handle:active_op():and_then(put)

  local inactive = self._handle:inactive_op():and_then(reason_op(mailbox):map(function(reason)
      return nil, reason
    end))

  return send:or_else(inactive)
end

function Tx:clone_op()
  local mailbox = self._mailbox
  return self._handle:clone_op():wrap(function(handle)
    return tx(mailbox, handle)
  end)
end

function Tx:close_op(reason)
  local mailbox = self._mailbox
  return self._handle:close_op():and_then(Op.guard(function(closed)
    if not closed then return Op.always(true) end
    return remember_reason_op(mailbox, reason):map(function()
      return true
    end)
  end))
end

function Tx:why_op()
  return reason_op(self._mailbox)
end


function Tx:dropped_op()
  return self._mailbox._dropped:read_op()
end


function Rx:recv_op()
  local mailbox = self._mailbox
  local closed = mailbox._senders:zero_op():and_then(reason_op(mailbox):map(function(reason)
      return nil, reason
    end))
  return mailbox._messages:get_op():or_else(closed)
end

function Rx:why_op()
  return reason_op(self._mailbox)
end


function Rx:dropped_op()
  return self._mailbox._dropped:read_op()
end









local function endpoint_label(self, ...)
  local mailbox = self._mailbox
  if select('#', ...) == 0 then return Label.get(mailbox) end
  Label.set(mailbox, select(1, ...), 2)
  return self
end

Tx.label = endpoint_label
Rx.label = endpoint_label

Mailbox.Tx = Tx
Mailbox.Rx = Rx

Direct.install(Tx, { 'why', 'dropped', 'send', 'clone', 'close' })
Direct.install(Rx, { 'why', 'dropped', 'recv' })

return Mailbox
