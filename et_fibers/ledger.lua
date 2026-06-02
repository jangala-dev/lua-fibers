local core = require('etfcore')
local Op = core.Op
local Cell = require('resources.cell')
local Log = require('resources.log')
local Signal = require('resources.signal')

local function shallow_copy(t)
  local u = {}
  if t then for k, v in pairs(t) do u[k] = v end end
  return u
end

local function read_proxy(cell)
  return setmetatable({}, {
    __index = function(_, k)
      return cell.value[k]
    end,
    __newindex = function()
      error('ledger public views are read-only; use ledger operations', 2)
    end,
  })
end

local function seq(a, b)
  return a:and_then(function() return b end)
end

local function append_then_emit(log, signal, record)
  return log:append_op(record):and_then(function(offset)
    return signal:wake_op():and_then(function()
      return Op.emit(record):map(function()
        return offset
      end)
    end)
  end)
end

-- --------------------------------------------------------------------------
-- Ledger protocol: derived from primitive resources.
--
-- Internal resources:
--   owners_cell : item  -> owner
--   closed_cell : owner -> close reason
--   events_log  : append-only ledger records
--   signal      : committed change notification
--
-- The ledger is intentionally no longer a native transactional resource.  Its
-- public operations are ordinary Op programs built from Cell, Log, Signal and
-- Emit.  This keeps ledger useful as an ownership/settlement example without
-- making ownership a privileged core primitive.
-- --------------------------------------------------------------------------

local Ledger = {}
Ledger.__index = Ledger

function Ledger.new(owners, name)
  local self = setmetatable({}, Ledger)
  self.name = name or 'ledger'
  self.owners_cell = Cell.new(shallow_copy(owners or {}), self.name .. '.owners')
  self.closed_cell = Cell.new({}, self.name .. '.closed')
  self.events_log = Log.new({}, self.name .. '.events')
  self.signal = Signal.new(self.name .. '.signal')

  -- Backwards-readable views used by demos/tests.  They deliberately do not
  -- construct Ops; all protocol actions must go through *_op methods.
  self.owners = read_proxy(self.owners_cell)
  self.closed = read_proxy(self.closed_cell)
  self.events = self.events_log.records
  return self
end

function Ledger:change_cursor()
  return self.signal:cursor()
end

function Ledger:changed_op(cursor)
  return self.signal:wait_op(cursor)
end

function Ledger:owner_op(item)
  return self.owners_cell:get_op():map(function(owners)
    return owners[item]
  end)
end

function Ledger:closed_op(owner)
  return self.closed_cell:get_op():map(function(closed)
    return closed[owner]
  end)
end

function Ledger:move_op(item, from_owner, to_owner)
  return self.owners_cell:get_op():and_then(function(owners)
    return self.closed_cell:get_op():and_then(function(closed)
      if closed[from_owner] then return Op.never() end
      if closed[to_owner] then return Op.never() end
      if owners[item] ~= from_owner then return Op.never() end

      local next_owners = shallow_copy(owners)
      next_owners[item] = to_owner

      local record = { tag = 'ledger.move', item = item, from = from_owner, to = to_owner }

      return self.owners_cell:set_op(next_owners):and_then(function()
        return append_then_emit(self.events_log, self.signal, record):map(function()
          return true
        end)
      end)
    end)
  end)
end

function Ledger:close_op(owner, reason)
  reason = reason or 'closed'

  return self.owners_cell:get_op():and_then(function(owners)
    return self.closed_cell:get_op():and_then(function(closed)
      if closed[owner] then return Op.never() end

      for item, item_owner in pairs(owners) do
        if item_owner == owner then
          return Op.never()
        end
      end

      local next_closed = shallow_copy(closed)
      next_closed[owner] = reason

      local record = { tag = 'ledger.close', owner = owner, reason = reason }

      return self.closed_cell:set_op(next_closed):and_then(function()
        return append_then_emit(self.events_log, self.signal, record):map(function()
          return true
        end)
      end)
    end)
  end)
end

return Ledger
