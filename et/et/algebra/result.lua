-- Result of evaluating an operation in the current instant.
-- cands are transaction candidates that can be searched now.
-- waits are future interests, reported only if no current world commits.
-- residuals are lazy or_else fallback points that may be opened only after
-- the current search environment proves absence of a committing world.
local Result = {}

local EMPTY = {}
Result.EMPTY = EMPTY

local NONE = { cands = EMPTY, waits = EMPTY, protected_nacks = EMPTY, residuals = EMPTY }
Result.NONE = NONE

local function empty(xs)
  return xs == nil or xs == EMPTY or #xs == 0
end

local function unique_append(dst, src)
  if empty(src) then return dst end
  if dst == nil or dst == EMPTY then dst = {} end
  for i = 1, #src do
    local x, found = src[i], false
    for j = 1, #dst do if dst[j] == x then found = true; break end end
    if not found then dst[#dst + 1] = x end
  end
  return dst
end

function Result.new(cands, waits, protected_nacks, residuals)
  if empty(cands) and empty(waits) and empty(protected_nacks) and empty(residuals) then return NONE end
  return {
    cands = cands or EMPTY,
    waits = waits or EMPTY,
    protected_nacks = protected_nacks or EMPTY,
    residuals = residuals or EMPTY,
  }
end

function Result.none()
  return NONE
end

function Result.cands(cands)
  if empty(cands) then return NONE end
  return { cands = cands, waits = EMPTY, protected_nacks = EMPTY, residuals = EMPTY }
end

function Result.wait(interest)
  if interest == nil then return NONE end
  return { cands = EMPTY, waits = { interest }, protected_nacks = EMPTY, residuals = EMPTY }
end

function Result.add_waits(r, waits)
  if empty(waits) then return r end
  if r == NONE then r = { cands = EMPTY, waits = EMPTY, protected_nacks = EMPTY, residuals = EMPTY } end
  r.waits = unique_append(r.waits, waits)
  return r
end

function Result.add_protected(r, refs)
  if empty(refs) then return r end
  if r == NONE then r = { cands = EMPTY, waits = EMPTY, protected_nacks = EMPTY, residuals = EMPTY } end
  r.protected_nacks = unique_append(r.protected_nacks, refs)
  return r
end

function Result.add_residuals(r, residuals)
  if empty(residuals) then return r end
  if r == NONE then r = { cands = EMPTY, waits = EMPTY, protected_nacks = EMPTY, residuals = EMPTY } end
  r.residuals = unique_append(r.residuals, residuals)
  return r
end

function Result.add_residual(r, residual)
  if residual == nil then return r end
  if r == NONE then r = { cands = EMPTY, waits = EMPTY, protected_nacks = EMPTY, residuals = EMPTY } end
  local xs = r.residuals
  if xs == nil or xs == EMPTY then
    r.residuals = { residual }
    return r
  end
  for i = 1, #xs do if xs[i] == residual then return r end end
  xs[#xs + 1] = residual
  return r
end

function Result.from(cands, waits, protected_nacks, residuals)
  if type(cands) == 'table' and cands.cands ~= nil and cands.waits ~= nil then return cands end
  return Result.new(cands, waits, protected_nacks, residuals)
end

Result._unique_append = unique_append
Result._empty = empty

return Result
