-- Closeable transactional mailbox built from Scalar + Queue/Rendezvous.
--
-- The mailbox is a compound facility.  Metadata (closed state, counted sender
-- handles and drop count) is a Scalar state machine.  Buffered storage is a
-- Queue; capacity-zero mailboxes rendezvous directly.

local Op = require('fibers.op')
local perform = require('fibers.perform')
local Scalar = require('fibers.scalar')
local Queue = require('fibers.internal.fifo')
local Rendezvous = require('fibers.resource.rendezvous')

local Mailbox = {}
local Tx = {}
local Rx = {}

Mailbox.__index = Mailbox
Tx.__index = Tx
Rx.__index = Rx

local next_mailbox_id = 0

local function sender_id_for(mailbox_id, seq)
  return tostring(mailbox_id) .. ':sender-' .. tostring(seq)
end

local function copy_senders(src)
  local out = {}
  for k, v in pairs(src or {}) do
    if v then
      out[k] = true
    end
  end
  return out
end

local function sender_count(senders)
  local n = 0
  for _, v in pairs(senders or {}) do
    if v then
      n = n + 1
    end
  end
  return n
end

local function copy_meta(st)
  st = st or {}
  return {
    closed = st.closed == true,
    reason = st.reason,
    senders = copy_senders(st.senders),
    dropped = st.dropped or 0,
    next_sender_seq = st.next_sender_seq or 0,
  }
end

local function active_sender(st, id)
  return id ~= nil and st and st.senders and st.senders[id] == true
end

local function inert_tx(mailbox)
  return setmetatable({ _mailbox = mailbox, _id = nil }, Tx)
end

local function counted_tx(mailbox, id)
  return setmetatable({ _mailbox = mailbox, _id = id }, Tx)
end

local Meta = Scalar.kind({
  name = 'mailbox.meta',
  transitions = {
    check_sendable = {
      mode = 'select',
      accepts_supply = true,
      supplies = 'any',
      order = 0,
      step = function(st, payload)
        st = copy_meta(st)
        if not st.closed and active_sender(st, payload.id) then
          return st, true
        end
        return nil
      end,
    },
    closed_or_inactive = {
      mode = 'select',
      accepts_supply = true,
      supplies = 'any',
      order = 10,
      step = function(st, payload)
        st = copy_meta(st)
        if st.closed or not active_sender(st, payload.id) then
          return st, nil, st.reason
        end
        return nil
      end,
    },
    closed = {
      mode = 'select',
      accepts_supply = true,
      supplies = 'any',
      order = 10,
      step = function(st)
        st = copy_meta(st)
        if st.closed then
          return st, nil, st.reason
        end
        return nil
      end,
    },
    clone_sender = {
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 20,
      step = function(st, payload)
        st = copy_meta(st)
        if st.closed or not active_sender(st, payload.id) then
          return st, inert_tx(payload.mailbox)
        end

        local seq = (st.next_sender_seq or 0) + 1
        local new_id = sender_id_for(payload.mailbox_id, seq)
        while st.senders[new_id] do
          seq = seq + 1
          new_id = sender_id_for(payload.mailbox_id, seq)
        end
        st.next_sender_seq = seq
        st.senders[new_id] = true
        return st, counted_tx(payload.mailbox, new_id)
      end,
    },
    close_sender = {
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 30,
      step = function(st, payload)
        st = copy_meta(st)
        if not active_sender(st, payload.id) then
          return st, true
        end
        if st.reason == nil and payload.reason ~= nil then
          st.reason = payload.reason
        end
        st.senders[payload.id] = nil
        if sender_count(st.senders) == 0 then
          st.closed = true
        end
        return st, true
      end,
    },
    close_mailbox = {
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 30,
      step = function(st, payload)
        st = copy_meta(st)
        if st.reason == nil and payload.reason ~= nil then
          st.reason = payload.reason
        end
        st.closed = true
        return st, true
      end,
    },
    drop = {
      mode = 'update',
      accepts_supply = true,
      supplies = 'any',
      order = 40,
      step = function(st)
        st = copy_meta(st)
        st.dropped = (st.dropped or 0) + 1
        return st, true, st.dropped
      end,
    },
  },
})

local function normalise_capacity(capacity)
  if capacity == nil then
    return 0
  end
  if type(capacity) ~= 'number' or capacity < 0 or capacity ~= math.floor(capacity) then
    error('mailbox capacity must be a non-negative integer', 3)
  end
  return capacity
end

local function normalise_full_policy(full, capacity)
  full = full or 'block'
  if full ~= 'block' and full ~= 'reject_newest' and full ~= 'drop_oldest' then
    error('mailbox full policy must be block, reject_newest or drop_oldest', 3)
  end
  if capacity == 0 and full == 'drop_oldest' then
    full = 'reject_newest'
  end
  return full
end

local function parse_new_args(capacity, opts)
  if type(capacity) == 'table' then
    opts = capacity
    capacity = opts.capacity
  end
  opts = opts or {}
  capacity = normalise_capacity(capacity)
  return capacity, opts
end

function Mailbox.new(capacity, opts)
  capacity, opts = parse_new_args(capacity, opts)
  next_mailbox_id = next_mailbox_id + 1
  local id = 'mailbox-' .. tostring(next_mailbox_id)
  local name = opts.name or id
  local sender_id = sender_id_for(id, 1)
  local full = normalise_full_policy(opts.full, capacity)
  local self = setmetatable({
    name = name,
    _mailbox_id = id,
    capacity = capacity,
    full = full,
    meta = opts.meta or Scalar.new({
      closed = false,
      reason = nil,
      senders = { [sender_id] = true },
      dropped = 0,
      next_sender_seq = 1,
    }, name .. ':meta'),
    queue = nil,
    rendezvous = nil,
  }, Mailbox)
  if capacity == 0 then
    self.rendezvous = opts.rendezvous or Rendezvous.new(name .. ':rendezvous')
  else
    self.queue = opts.queue or Queue.new({ capacity = capacity, name = name .. ':queue' })
  end
  return counted_tx(self, sender_id), setmetatable({ _mailbox = self }, Rx)
end

local function require_sendable_op(mailbox, id)
  return mailbox.meta:transition_op(Meta:transition('check_sendable'), { id = id })
end

local function closed_or_inactive_op(mailbox, id)
  return mailbox.meta:transition_op(Meta:transition('closed_or_inactive'), { id = id })
end

local function closed_op(mailbox)
  return mailbox.meta:transition_op(Meta:transition('closed'))
end

local function drop_op(mailbox)
  return mailbox.meta:transition_op(Meta:transition('drop'))
end

local function put_raw_op(mailbox, value)
  if mailbox.queue then
    return mailbox.queue:put_op(value)
  end
  return mailbox.rendezvous:put_op(value)
end

local function get_raw_op(mailbox)
  if mailbox.queue then
    return mailbox.queue:get_op()
  end
  return mailbox.rendezvous:get_op()
end

local function accepted_put_op(mailbox, value)
  local put = put_raw_op(mailbox, value):map(function()
    return true
  end)
  if mailbox.full == 'block' then
    return put
  end
  if mailbox.full == 'reject_newest' then
    return put:or_else(drop_op(mailbox):map(function()
      return false, 'full'
    end))
  end
  local drop_oldest = Op.tensor({
    mailbox.queue:get_op(),
    mailbox.queue:put_op(value),
    drop_op(mailbox),
  }):map(function()
    return true
  end)
  return put:or_else(drop_oldest)
end

function Tx:send_op(value)
  if value == nil then
    error('mailbox send_op does not accept nil payloads', 2)
  end
  local mailbox, id = self._mailbox, self._id
  if not mailbox or id == nil then
    return Op.always(nil)
  end
  local send = require_sendable_op(mailbox, id):and_then(function()
    return accepted_put_op(mailbox, value)
  end)
  return send:or_else(closed_or_inactive_op(mailbox, id))
end

function Tx:clone_op()
  local mailbox, id = self._mailbox, self._id
  if not mailbox or id == nil then
    return Op.always(inert_tx(mailbox))
  end
  return mailbox.meta:transition_op(
    Meta:transition('clone_sender'),
    { id = id, mailbox = mailbox, mailbox_id = mailbox._mailbox_id }
  )
end

function Tx:close_op(reason)
  local mailbox, id = self._mailbox, self._id
  if not mailbox or id == nil then
    return Op.always(true)
  end
  return mailbox.meta:transition_op(Meta:transition('close_sender'), { id = id, reason = reason })
end

function Tx:why_op()
  return self._mailbox.meta:read_op():map(function(st)
    return st and st.reason or nil
  end)
end

function Tx:dropped_op()
  return self._mailbox.meta:read_op():map(function(st)
    return st and st.dropped or 0
  end)
end

function Tx:snapshot_op()
  return self._mailbox:snapshot_op()
end

function Rx:recv_op()
  local mailbox = self._mailbox
  return get_raw_op(mailbox):or_else(closed_op(mailbox))
end

function Rx:why_op()
  return self._mailbox.meta:read_op():map(function(st)
    return st and st.reason or nil
  end)
end

function Rx:dropped_op()
  return self._mailbox.meta:read_op():map(function(st)
    return st and st.dropped or 0
  end)
end

function Rx:snapshot_op()
  return self._mailbox:snapshot_op()
end

function Mailbox:snapshot_op()
  local storage = self.queue and self.queue:snapshot_op() or Op.always({})
  return Op.all({ self.meta:read_op(), storage }):map(function(rows)
    local st = copy_meta(rows[1][1])
    return {
      closed = st.closed,
      reason = st.reason,
      senders = st.senders,
      sender_count = sender_count(st.senders),
      dropped = st.dropped or 0,
      next_sender_seq = st.next_sender_seq or 0,
      capacity = self.capacity,
      full = self.full,
      items = rows[2][1],
    }
  end)
end

Mailbox.Tx = Tx
Mailbox.Rx = Rx
Mailbox.Meta = Meta
function Tx:send(value) return perform(self:send_op(value)) end

function Tx:clone() return perform(self:clone_op()) end

function Tx:close(reason) return perform(self:close_op(reason)) end

function Rx:recv() return perform(self:recv_op()) end


return Mailbox
