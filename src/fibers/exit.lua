-- Task Exit values.
--
-- Exit is the small terminal fact recorded by Task completion.  It is not a
-- scope report and it is not a status tuple.  It preserves Lua's multiple
-- return values for successful tasks, while failed/cancelled exits can be
-- inspected by policy code or unwrapped by Task:await_op at the perform boundary.

local Runtime = require('fibers.kernel.runtime')

local Exit = {}
Exit.__index = Exit

local unpack_ = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function new(tag, fields)
  fields = fields or {}
  fields.tag = tag
  fields._fibers_exit = true
  return setmetatable(fields, Exit)
end

function Exit.returned(...)
  return new('returned', { values = pack(...) })
end

function Exit.failed(err)
  return new('failed', { error = err })
end

function Exit.cancelled(reason, token)
  return new('cancelled', { reason = reason, token = token })
end

function Exit.is(x)
  return type(x) == 'table' and x._fibers_exit == true
end

function Exit.status(x)
  return Exit.is(x) and x.tag or nil
end

function Exit.unwrap(x)
  if not Exit.is(x) then
    error('Exit.unwrap expects an Exit value', 2)
  end
  if x.tag == 'returned' then
    local vals = x.values or { n = 0 }
    return unpack_(vals, 1, vals.n or #vals)
  elseif x.tag == 'cancelled' then
    error(Runtime.cancelled(x.reason, x.token), 0)
  elseif x.tag == 'failed' then
    error(x.error, 0)
  end
  error('unknown task exit tag ' .. tostring(x.tag), 2)
end

function Exit:tostring()
  if self.tag == 'returned' then
    return 'Exit.returned'
  end
  if self.tag == 'cancelled' then
    return 'Exit.cancelled: ' .. tostring(self.reason)
  end
  if self.tag == 'failed' then
    return 'Exit.failed: ' .. tostring(self.error)
  end
  return 'Exit.' .. tostring(self.tag)
end

Exit.__tostring = Exit.tostring

return Exit
