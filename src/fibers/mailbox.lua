-- Closeable mailbox from Channel + RefCount + Cell + Counter.

local Channel = require('fibers.channel')
local RefCount = require('fibers.resource.ref_count')
local Cell = require('fibers.resource.cell')
local Counter = require('fibers.resource.counter')
local Op = require('fibers.op')
local perform = require('fibers.perform')

local Mailbox = {}
local Tx = {}
local Rx = {}

Mailbox.__index = Mailbox
Tx.__index = Tx
Rx.__index = Rx

local NO_REASON = {}

local function child_name(name, suffix)
  return name and name .. ':' .. suffix or nil
end

local function tx(mailbox, handle)
  return setmetatable({ _mailbox = mailbox, _handle = handle }, Tx)
end

local function reason_op(mailbox)
  return mailbox._reason:read_op():map(function(reason)
    return reason ~= NO_REASON and reason or nil
  end)
end

local function remember_reason_op(mailbox, reason)
  if reason == nil then
    return Op.always(true)
  end

  local remember = mailbox._reason:expect_op(NO_REASON):and_then(mailbox._reason:write_op(reason))

  return remember:or_else(mailbox._reason
    :wait_until_op(function(value)
      return value ~= NO_REASON
    end)
    :map(function()
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

local function new_mailbox(capacity, name, accept, full)
  capacity = capacity or 0
  if type(capacity) ~= 'number' or capacity < 0 or capacity % 1 ~= 0 then
    error('mailbox capacity must be a non-negative integer', 3)
  end

  local refs, first = RefCount.new(child_name(name, 'senders'))
  local mailbox = setmetatable({
    capacity = capacity,
    full = full,
    _accept = accept,
    _messages = Channel.new(capacity, child_name(name, 'messages')),
    _senders = refs,
    _reason = Cell.new(NO_REASON, child_name(name, 'reason')),
    _dropped = Counter.new(0, child_name(name, 'dropped')),
  }, Mailbox)

  return tx(mailbox, first), setmetatable({ _mailbox = mailbox }, Rx)
end

function Mailbox.new(capacity, name)
  return new_mailbox(capacity, name, block, 'block')
end

function Mailbox.reject_newest(capacity, name)
  return new_mailbox(capacity, name, reject_newest, 'reject_newest')
end

function Mailbox.drop_oldest(capacity, name)
  capacity = capacity or 0
  if capacity == 0 then
    return Mailbox.reject_newest(0, name)
  end
  return new_mailbox(capacity, name, drop_oldest, 'drop_oldest')
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
    if not closed then
      return Op.always(true)
    end
    return remember_reason_op(mailbox, reason):map(function()
      return true
    end)
  end))
end

function Tx:why_op()
  return reason_op(self._mailbox)
end

function Tx:why()
  return perform(self:why_op())
end

function Tx:dropped_op()
  return self._mailbox._dropped:read_op()
end

function Tx:dropped()
  return perform(self:dropped_op())
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

function Rx:why()
  return perform(self:why_op())
end

function Rx:dropped_op()
  return self._mailbox._dropped:read_op()
end

function Rx:dropped()
  return perform(self:dropped_op())
end

function Tx:send(value)
  return perform(self:send_op(value))
end

function Tx:clone()
  return perform(self:clone_op())
end

function Tx:close(reason)
  return perform(self:close_op(reason))
end

function Rx:recv()
  return perform(self:recv_op())
end

Mailbox.Tx = Tx
Mailbox.Rx = Rx

return Mailbox
