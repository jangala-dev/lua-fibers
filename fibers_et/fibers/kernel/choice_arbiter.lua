-- Deterministic committed arbitration for unordered choice.
--
-- Search may inspect an order any number of times, but arbitration state moves
-- only when the world containing a selected branch commits.

local Arbiter = {}
Arbiter.__index = Arbiter

local MODULUS = 2147483647
local MULTIPLIER = 16807

local function hash_text(seed, text)
  local h = seed % MODULUS
  if h <= 0 then h = 1 end
  text = tostring(text or '')
  for i = 1, #text do
    h = (h * 131 + string.byte(text, i)) % MODULUS
    if h == 0 then h = 1 end
  end
  return h
end

local function normalise_seed(seed)
  if seed ~= nil and type(seed) ~= 'number' and type(seed) ~= 'string' then
    error('choice.seed must be a number or string', 3)
  end
  if type(seed) == 'number' then
    local n = math.floor(math.abs(seed)) % MODULUS
    return n == 0 and 1 or n
  end
  return hash_text(1, seed == nil and 'fibers-choice-v1' or seed)
end

local function next_random(state)
  return (state * MULTIPLIER) % MODULUS
end

local function permutation(count, seed)
  local out = {}
  for i = 1, count do out[i] = i end
  local state = seed
  for i = count, 2, -1 do
    state = next_random(state)
    local j = (state % i) + 1
    out[i], out[j] = out[j], out[i]
  end
  return out
end

local function explicit_label(key)
  if type(key) == 'table' and key._fibers_choice_key then
    return key.name or key.id or tostring(key)
  end
  return key
end

function Arbiter.new(opts)
  opts = opts or {}
  local mode = opts.mode or 'rotating'
  if mode ~= 'rotating' then
    error('choice.mode must be "rotating"', 2)
  end
  return setmetatable({
    mode = mode,
    seed = normalise_seed(opts.seed),
    owners = {},
  }, Arbiter)
end

function Arbiter:discard_owner(owner_id)
  self.owners[owner_id] = nil
end

function Arbiter:_owner(owner_id)
  local owner = self.owners[owner_id]
  if not owner then
    owner = {
      explicit = {},
      implicit = setmetatable({}, { __mode = 'k' }),
    }
    self.owners[owner_id] = owner
  end
  return owner
end

local function ensure_count(state, count)
  if state.count ~= count then
    error('choice arbitration key reused with a different branch count', 3)
  end
end

function Arbiter:_state(owner_id, op, occurrence, count)
  local owner = self:_owner(owner_id)
  local state
  local identity_label

  if rawget(op, '_choice_key') ~= nil then
    state = owner.explicit[rawget(op, '_choice_key')]
    identity_label = 'explicit\0' .. tostring(explicit_label(rawget(op, '_choice_key')))
    if not state then
      local seed = hash_text(hash_text(self.seed, owner_id), identity_label)
      state = {
        count = count,
        permutation = permutation(count, seed),
        next_position = 1,
      }
      owner.explicit[rawget(op, '_choice_key')] = state
    else
      ensure_count(state, count)
    end
    return state
  end

  local by_path = owner.implicit[op]
  if not by_path then
    by_path = {}
    owner.implicit[op] = by_path
  end
  state = by_path[occurrence]
  identity_label = 'implicit\0' .. tostring(op._id or op) .. '\0' .. tostring(occurrence or '')
  if not state then
    local seed = hash_text(hash_text(self.seed, owner_id), identity_label)
    state = {
      count = count,
      permutation = permutation(count, seed),
      next_position = 1,
    }
    by_path[occurrence] = state
  else
    ensure_count(state, count)
  end
  return state
end

function Arbiter:order(owner_id, op, occurrence, count)
  if count < 1 then return { order = {}, state = nil } end
  local state = self:_state(owner_id, op, occurrence, count)
  local order = {}
  local start = state.next_position or 1
  for offset = 0, count - 1 do
    local position = ((start - 1 + offset) % count) + 1
    order[#order + 1] = state.permutation[position]
  end
  return { order = order, state = state }
end

function Arbiter:commit(selections)
  for i = 1, #(selections or {}) do
    local selection = selections[i]
    local state = selection and selection.state
    local branch = selection and selection.branch
    if state and branch then
      local position
      for j = 1, state.count do
        if state.permutation[j] == branch then
          position = j
          break
        end
      end
      if not position then
        error('committed choice selection is not present in its arbitration permutation', 2)
      end
      state.next_position = (position % state.count) + 1
    end
  end
end

return Arbiter
