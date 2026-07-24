-- Borrow: temporary authority as an owned obligation.
--
-- A borrow grants use authority for a subject without moving custody of that
-- subject.  The borrow handle itself is owned by the borrower scope.  When the
-- borrower scope settles, the borrow settlement releases its compatibility
-- leases, so the granted authority has an ordinary lifetime.

local Op = require('fibers.op')
local Ownership = require('fibers.lifetime.ownership')
local Settlement = require('fibers.lifetime.settlement')

local Borrow = {}
Borrow.__index = Borrow

local next_id = 0

local function list_rights(rights)
  if rights == nil then
    return { 'use' }
  end
  if type(rights) == 'string' then
    return { rights }
  end
  if type(rights) ~= 'table' then
    error('borrow rights must be a string or table', 3)
  end
  local out = {}
  local is_array = #rights > 0
  if is_array then
    for i = 1, #rights do
      if type(rights[i]) ~= 'string' then
        error('borrow rights list must contain strings', 3)
      end
      out[#out + 1] = rights[i]
    end
  else
    for k, v in pairs(rights) do
      if v then
        if type(k) ~= 'string' then
          error('borrow rights map keys must be strings', 3)
        end
        out[#out + 1] = k
      end
    end
    table.sort(out)
  end
  if #out == 0 then
    error('borrow rights must not be empty', 3)
  end
  return out
end

local function rights_set(list)
  local set = {}
  for i = 1, #list do
    set[list[i]] = true
  end
  return set
end

local function mode_owner(id, mode)
  return id .. ':' .. tostring(mode)
end

local function release_all_op(borrow)
  local ops = {}
  for i = 1, #(borrow.right_list or {}) do
    local mode = borrow.right_list[i]
    ops[#ops + 1] = borrow.lease:release_op(borrow.subject, mode_owner(borrow._fibers_id, mode))
  end
  if #ops == 0 then
    return Op.always(true)
  end
  return Op.all(ops):map(function()
    return true
  end)
end

function Borrow.new(grantor_scope, borrower_scope, subject, rights, opts)
  opts = opts or {}
  if subject == nil then
    error('Borrow.new expects a subject', 2)
  end
  if not grantor_scope or not grantor_scope._fibers_scope then
    error('Borrow.new expects a grantor Scope', 2)
  end
  if not borrower_scope or not borrower_scope._fibers_scope then
    error('Borrow.new expects a borrower Scope', 2)
  end
  if not opts.lease then
    error('Borrow.new expects opts.lease', 2)
  end
  next_id = next_id + 1
  local id = 'borrow-' .. tostring(next_id)
  local list = list_rights(rights)
  local b = Ownership.handle(opts.name or id, {
    kind = 'borrow',
    _fibers_borrow = true,
    subject = subject,
    grantor_scope = grantor_scope,
    borrower_scope = borrower_scope,
    lease = opts.lease,
    right_list = list,
    rights = rights_set(list),
    meta = opts.meta,
    settle = Settlement.protocol({
      name = 'borrow',
      discharge_op = function(_ctx, record)
        return release_all_op(record.item)
      end,
    }),
    settle_name = 'borrow',
  })
  b._fibers_id = b._fibers_id or id
  setmetatable(b, Borrow)
  return b
end

function Borrow.is(x)
  return type(x) == 'table' and x._fibers_borrow == true
end

function Borrow.rights_list(rights)
  return list_rights(rights)
end

function Borrow:has_right(right)
  if right == nil then
    return true
  end
  if self.rights and (self.rights[right] or self.rights['*']) then
    return true
  end
  -- Owners commonly check for a general use right.
  if right == 'use' and self.rights then
    return self.rights.read
      or self.rights.write
      or self.rights.observe
      or self.rights.use
      or self.rights['*']
      or false
  end
  return false
end

function Borrow:release_op()
  return release_all_op(self)
end

function Borrow:inspect()
  return {
    subject = self.subject,
    grantor_scope = self.grantor_scope,
    borrower_scope = self.borrower_scope,
    rights = self.rights,
    right_list = self.right_list,
    lease = self.lease,
  }
end

return Borrow
