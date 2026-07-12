-- Deterministic, runtime-local ordering for semantically unordered choices.
--
-- The permutation is a pure function of replay-visible runtime state and the
-- dynamic choice occurrence. It does not consume Lua's process-global RNG, so
-- speculative search and rollback cannot perturb later decisions.

local M = {}

local MOD = 2147483647 -- 2^31 - 1; arithmetic remains exact in Lua doubles.
local MUL = 48271

local function residue(x)
  x = tonumber(x) or 0
  return math.floor(x) % MOD
end

local function initial_seed(x)
  local seed = residue(x)
  if seed == 0 then return 1 end
  return seed
end

local function step(state, salt)
  return (state * MUL + residue(salt)) % MOD
end

function M.indices(runtime, task, occurrence, n)
  local order = {}
  for i = 1, n do order[i] = i end
  if n < 2 then return order end

  local state = initial_seed(runtime.choice_seed)
  state = step(state, runtime.epoch or 0)
  state = step(state, runtime.pending_generation or 0)
  state = step(state, task.root_id or 0)
  state = step(state, task.id or 0)
  state = step(state, occurrence or 0)

  for i = n, 2, -1 do
    state = step(state, i)
    local j = (state % i) + 1
    order[i], order[j] = order[j], order[i]
  end
  return order
end

return M
