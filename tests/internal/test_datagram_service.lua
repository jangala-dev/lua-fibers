package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './reference/?.lua', './reference/?/init.lua', './reference/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local Service = require('fibers.internal.socket.datagram_service')

local function fake_handle(read_ready, write_ready)
  return {
    read_ready_op = function()
      return read_ready and Op.always(true) or Op.never()
    end,
    write_ready_op = function()
      return write_ready and Op.always(true) or Op.never()
    end,
  }
end

local function fake_sends(record)
  return {
    next_op = function()
      return record and Op.always(record) or Op.never()
    end,
  }
end

local function select(service, handle, sends, pending)
  local event, held
  fibers.run(function()
    event, held = fibers.perform(service:next_op(handle, sends, pending))
  end)
  return event, held
end

local service = Service.new(1)
local record = { seq = 1, data = 'x' }

-- Read is initially preferred when both directions are serviceable.
local event, pending = select(service, fake_handle(true, true), fake_sends(record))
assert(event.kind == 'read')
assert(pending == nil or pending == record)
service:progress('read')
assert(service:snapshot().preferred == 'write')

-- After one read, write is preferred and selected even if read is also ready.
event, pending = select(service, fake_handle(true, true), fake_sends(record), pending)
assert(event.kind == 'write')
assert(pending == record)
service:progress('write')
assert(service:snapshot().preferred == 'read')

-- An unavailable preferred side does not prevent useful progress.
event = select(service, fake_handle(false, true), fake_sends(nil), record)
assert(event.kind == 'write')
assert(service:snapshot().preferred == 'read')

-- A larger quantum permits a bounded run before preference changes.
local batched = Service.new(2)
batched:progress('read')
assert(batched:snapshot().preferred == 'read')
batched:progress('read')
assert(batched:snapshot().preferred == 'write')

print('tests/internal/test_datagram_service.lua: ok')
