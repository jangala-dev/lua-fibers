-- Grant: a Lifetime carrying selected authority over another Lifetime.
--
-- Custody remains unique and structural. A Grant is non-custodial authority
-- held as an ordinary child Lifetime; closing it revokes the authority.
-- A Grant is permission, not a lock or reservation. Exclusive access must be
-- represented explicitly by the subject facility or another transactional resource.
local Lifetime = require('fibers.lifetime')
local Closure = require('fibers.closure')
local Label = require('fibers.internal.label')
local Direct = require('fibers.internal.direct')
local Contract = require('fibers.internal.contract')

local Grant = {}
Grant.__index = Grant

-- Authority-bearing data is private. Public Lua fields are mutable and must not
-- be authoritative for rights, subjects or transfer terms. Store the snapshot
-- behind an unforgeable local table key on the Grant itself. A global weak-key
-- registry would leak on Lua 5.1 when its value can reach the Grant through the
-- Runtime-local Lifetime tree (Lua 5.1 has no ephemeron semantics).
local PRIVATE_STATE = {}

local function state(grant, level)
  local value = type(grant) == 'table' and rawget(grant, PRIVATE_STATE) or nil
  if type(value) ~= 'table' then error('invalid Grant', (level or 1) + 1) end
  return value
end

local function normalise_rights(rights)
  if rights == nil then rights = { 'use' }
  elseif type(rights) == 'string' then rights = { rights }
  elseif type(rights) ~= 'table' then
    error('Grant rights must be a string, dense array, or string-keyed set', 3)
  end

  local out = {}
  if #rights > 0 then
    Contract.dense(rights, 'Grant rights', 3)
    for i = 1, #rights do
      local right = rights[i]
      if type(right) ~= 'string' then error('Grant rights array must contain strings', 3) end
      if out[right] then error('Grant rights must not contain duplicates', 3) end
      out[right] = true
    end
  else
    for right, enabled in pairs(rights) do
      if type(right) ~= 'string' or type(enabled) ~= 'boolean' then
        error('Grant rights set must map string rights to booleans', 3)
      end
      if enabled then out[right] = true end
    end
  end
  if next(out) == nil then error('Grant rights must not be empty', 3) end
  return out
end

function Grant._new(grantor, holder, subject, rights, opts)
  opts = Contract.options(opts, { label = true, terms = true, meta = true }, 'Grant options', 2)
  if subject == nil then error('Grant creation expects a subject', 2) end
  if type(grantor) ~= 'table' or grantor._fibers_scope ~= true then
    error('Grant creation expects a grantor Scope', 2)
  end
  if type(holder) ~= 'table' or holder._fibers_scope ~= true then
    error('Grant creation expects a holder Scope', 2)
  end
  local subject_lifetime = Lifetime.require(subject, 3)
  local runtime = grantor._lifetime._runtime
  if not runtime or runtime ~= holder._lifetime._runtime then
    error('Grant scopes must belong to the same Runtime', 2)
  end
  runtime._next_grant_id = (runtime._next_grant_id or 0) + 1
  local id = 'grant-' .. tostring(runtime._next_grant_id)
  local rights_map = normalise_rights(rights)
  if opts.label ~= nil then Contract.non_empty_string(opts.label, 'Grant option label', 2) end
  if opts.meta ~= nil then Contract.table(opts.meta, 'Grant meta', 2) end
  local terms = Contract.copy_table(opts.terms, 'Grant terms', 2)
  for key in pairs(terms) do
    if key ~= 'transferable' then
      error('unsupported Grant term ' .. tostring(key), 2)
    end
  end
  if terms.transferable == nil then terms.transferable = false end
  if type(terms.transferable) ~= 'boolean' then
    error('Grant term transferable must be a boolean', 2)
  end
  local grantor_lifetime = grantor:lifetime()
  local holder_lifetime = holder:lifetime()
  local grant = Label.attach(setmetatable({
    _fibers_id = id,
  }, Grant), opts.label)

  local private_state = {
    subject_lifetime = subject_lifetime, rights = rights_map, transferable = terms.transferable,
  }
  rawset(grant, PRIVATE_STATE, private_state)

  -- Authorisation and transfer checks use only the private immutable grant state.
  Lifetime.define(grant, {
    label = opts.label,
    role = 'grant',
    meta = {
      subject = subject,
      subject_lifetime = subject_lifetime,
      grantor = grantor_lifetime,
      holder = holder_lifetime,
      rights = Contract.copy_table(rights_map),
      terms = Contract.copy_table(terms),
    },
    closure = Closure.none(),
  })
  return grant
end

function Grant.is(value)
  return type(value) == 'table' and type(rawget(value, PRIVATE_STATE)) == 'table'
end

function Grant._subject_lifetime(grant)
  return state(grant, 2).subject_lifetime
end

function Grant._right_list(grant)
  local out = {}
  for right in pairs(state(grant, 2).rights) do out[#out + 1] = right end
  table.sort(out)
  return out
end

function Grant._is_transferable(grant)
  return state(grant, 2).transferable == true
end

function Grant:has_right(right)
  right = right or 'use'
  local rights = state(self, 2).rights
  if rights[right] or rights['*'] then return true end
  if right == 'use' then
    return rights.read or rights.write or rights.observe or rights.use or rights['*'] or false
  end
  return false
end

function Grant:retired_op()
  return Lifetime.require(self):retired_op():map(function()
    return self
  end)
end



Direct.install(Grant, { 'retired' })

return Grant
