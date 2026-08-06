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

local Grant = {}
Grant.__index = Grant

-- Authority-bearing data is private. Public Lua fields are mutable and must not
-- be authoritative for rights, subjects or transfer terms. Store the snapshot
-- behind an unforgeable local table key on the Grant itself. A global weak-key
-- registry would leak on Lua 5.1 when its value can reach the Grant through the
-- Runtime-local Lifetime forest (Lua 5.1 has no ephemeron semantics).
local PRIVATE_STATE = {}

local function state(grant, level)
  local value = type(grant) == 'table' and rawget(grant, PRIVATE_STATE) or nil
  if type(value) ~= 'table' then error('invalid Grant', (level or 1) + 1) end
  return value
end

local function copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do out[key] = item end
  return out
end

local function copy_list(value)
  local out = {}
  for i = 1, #(value or {}) do out[i] = value[i] end
  return out
end

local function list_rights(rights)
  if rights == nil then return { 'use' } end
  if type(rights) == 'string' then return { rights } end
  if type(rights) ~= 'table' then
    error('Grant rights must be a string, dense array, or string-keyed set', 3)
  end

  local numeric, named, max_index = 0, 0, 0
  for key, value in pairs(rights) do
    if type(key) == 'number' then
      if key < 1 or key % 1 ~= 0 then
        error('Grant rights array indices must be positive integers', 3)
      end
      numeric = numeric + 1
      if key > max_index then max_index = key end
      if type(value) ~= 'string' then
        error('Grant rights array must contain strings', 3)
      end
    else
      named = named + 1
      if type(key) ~= 'string' or type(value) ~= 'boolean' then
        error('Grant rights set must map string rights to booleans', 3)
      end
    end
  end

  local out = {}
  if numeric > 0 then
    if named > 0 or numeric ~= max_index then
      error('Grant rights array must be dense and contain no named entries', 3)
    end
    for i = 1, max_index do out[i] = rights[i] end
  else
    for right, enabled in pairs(rights) do
      if enabled then out[#out + 1] = right end
    end
    table.sort(out)
  end
  if #out == 0 then error('Grant rights must not be empty', 3) end

  local seen = {}
  for i = 1, #out do
    if seen[out[i]] then error('Grant rights must not contain duplicates', 3) end
    seen[out[i]] = true
  end
  return out
end

local function rights_set(list)
  local out = {}
  for i = 1, #list do out[list[i]] = true end
  return out
end

function Grant._new(grantor, holder, subject, rights, opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('Grant options must be a table', 2)
  end
  opts = opts or {}
  if subject == nil then error('Grant creation expects a subject', 2) end
  if type(grantor) ~= 'table' or grantor._fibers_scope ~= true then
    error('Grant creation expects a grantor Scope', 2)
  end
  if type(holder) ~= 'table' or holder._fibers_scope ~= true then
    error('Grant creation expects a holder Scope', 2)
  end
  local subject_lifetime = Lifetime.require(subject, 3)
  local runtime = grantor.runtime
  if not runtime or runtime ~= holder.runtime then
    error('Grant scopes must belong to the same Runtime', 2)
  end
  runtime._next_grant_id = (runtime._next_grant_id or 0) + 1
  local id = 'grant-' .. tostring(runtime._next_grant_id)
  local right_list = list_rights(rights)
  if opts.label ~= nil and type(opts.label) ~= 'string' then
    error('Grant option label must be a string', 2)
  end
  if opts.terms ~= nil and type(opts.terms) ~= 'table' then
    error('Grant terms must be a table', 2)
  end
  local terms = copy_table(opts.terms)
  for key in pairs(terms) do
    if key ~= 'transferable' then
      error('unsupported Grant term ' .. tostring(key), 2)
    end
  end
  if terms.transferable == nil then terms.transferable = false end
  if type(terms.transferable) ~= 'boolean' then
    error('Grant term transferable must be a boolean', 2)
  end
  local rights_map = rights_set(right_list)
  local grantor_lifetime = grantor:lifetime()
  local holder_lifetime = holder:lifetime()
  local grant = Label.attach(setmetatable({
    _fibers_id = id,
  }, Grant), opts.label)

  local private_state = {
    subject = subject,
    subject_lifetime = subject_lifetime,
    grantor = grantor_lifetime,
    initial_holder = holder_lifetime,
    right_list = right_list,
    rights = rights_map,
    terms = terms,
    meta = opts.meta,
  }
  rawset(grant, PRIVATE_STATE, private_state)

  -- Metadata is diagnostic only. Authorisation and transfer checks use the
  -- private snapshot above, never this publicly inspectable table.
  Lifetime.define(grant, {
    label = opts.label,
    role = 'grant',
    meta = {
      subject = subject,
      subject_lifetime = subject_lifetime,
      grantor = grantor_lifetime,
      holder = holder_lifetime,
      rights = copy_table(rights_map),
      terms = copy_table(terms),
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
  return copy_list(state(grant, 2).right_list)
end

function Grant._is_transferable(grant)
  return state(grant, 2).terms.transferable == true
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

function Grant:closed_op()
  return Lifetime.require(self):closed_op():map(function()
    return self
  end)
end


function Grant:inspect()
  local value = state(self, 2)
  return {
    subject = value.subject,
    grantor = value.grantor,
    holder = Lifetime.require(self):current_state().custodian,
    subject_lifetime = value.subject_lifetime,
    rights = copy_table(value.rights),
    right_list = copy_list(value.right_list),
    terms = copy_table(value.terms),
    meta = copy_table(value.meta),
  }
end

Direct.install(Grant, { 'closed' })

return Grant
