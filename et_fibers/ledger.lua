local core = require('etfcore')
local Op = core.Op

local function shallow_copy(t)
  local u = {}
  if t then for k, v in pairs(t) do u[k] = v end end
  return u
end

local function list_copy(xs)
  local ys = {}
  if xs then for i = 1, #xs do ys[i] = xs[i] end end
  return ys
end

-- --------------------------------------------------------------------------
-- Ledger resource: native fragments + commit events.
--
-- State: item -> owner, and closed owners.
-- Fragment: planned moves and closes.  Transfer+close-source is legal if the
-- close leaves the owner with no remaining items after planned moves.
-- --------------------------------------------------------------------------

local Ledger = {}
Ledger.__index = Ledger

function Ledger.new(owners)
  return setmetatable({ owners = shallow_copy(owners or {}), closed = {} }, Ledger)
end

function Ledger:move(item, from_owner, to_owner)
  return Op.access(self, { tag = 'move', item = item, from = from_owner, to = to_owner })
end

function Ledger:close(owner, reason)
  return Op.access(self, { tag = 'close', owner = owner, reason = reason or 'closed' })
end

function Ledger:empty_fragment()
  return { moves = {}, move_order = {}, closes = {}, close_order = {} }
end

local function ledger_clone_fragment(f)
  local g = { moves = {}, move_order = list_copy(f.move_order), closes = {}, close_order = list_copy(f.close_order) }
  for k, v in pairs(f.moves or {}) do g.moves[k] = { item = v.item, from = v.from, to = v.to } end
  for k, v in pairs(f.closes or {}) do g.closes[k] = { owner = v.owner, reason = v.reason } end
  return g
end

function Ledger:step_fragment(fragment, request)
  local f = ledger_clone_fragment(fragment)

  if request.tag == 'move' then
    local old = f.moves[request.item]
    local move = { item = request.item, from = request.from, to = request.to }
    if old and (old.from ~= move.from or old.to ~= move.to) then
      return false, 'conflicting move for ' .. tostring(request.item)
    end
    if not old then f.move_order[#f.move_order + 1] = request.item end
    f.moves[request.item] = move
    return true, { value = true }, f

  elseif request.tag == 'close' then
    local old = f.closes[request.owner]
    local close = { owner = request.owner, reason = request.reason }
    if old and old.reason ~= close.reason then
      return false, 'conflicting close for ' .. tostring(request.owner)
    end
    if not old then f.close_order[#f.close_order + 1] = request.owner end
    f.closes[request.owner] = close
    return true, { value = true }, f
  end

  return false, 'unknown ledger request'
end

function Ledger:step_fragment_with_view(view_fragment, local_fragment, request)
  -- Ledger requests currently do not return values that depend on pending state,
  -- so the local delta can be stepped directly.  This method documents the
  -- base-aware resource protocol: view_fragment is available for reads, while
  -- the returned fragment must be the next local contribution only.
  return self:step_fragment(local_fragment, request)
end

function Ledger:merge_fragments(a, b)
  local out = ledger_clone_fragment(a)

  for _, item in ipairs(b.move_order or {}) do
    local mv = b.moves[item]
    local old = out.moves[item]
    if old and (old.from ~= mv.from or old.to ~= mv.to) then
      return false, 'conflicting move for ' .. tostring(item)
    end
    if not old then out.move_order[#out.move_order + 1] = item end
    out.moves[item] = { item = mv.item, from = mv.from, to = mv.to }
  end

  for _, owner in ipairs(b.close_order or {}) do
    local cl = b.closes[owner]
    local old = out.closes[owner]
    if old and old.reason ~= cl.reason then
      return false, 'conflicting close for ' .. tostring(owner)
    end
    if not old then out.close_order[#out.close_order + 1] = owner end
    out.closes[owner] = { owner = cl.owner, reason = cl.reason }
  end

  return true, out
end

function Ledger:validate_fragment(fragment)
  -- Validate moves against committed state and planned closes.
  local planned_owner = shallow_copy(self.owners)

  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    if self.closed[mv.from] then return false, 'source owner already closed: ' .. tostring(mv.from) end
    if self.closed[mv.to] then return false, 'target owner already closed: ' .. tostring(mv.to) end
    if planned_owner[item] ~= mv.from then
      return false, 'owner mismatch for ' .. tostring(item) .. ': expected ' .. tostring(mv.from) .. ', have ' .. tostring(planned_owner[item])
    end
    planned_owner[item] = mv.to
  end

  for _, owner in ipairs(fragment.close_order or {}) do
    if self.closed[owner] then return false, 'already closed: ' .. tostring(owner) end
    for item, item_owner in pairs(planned_owner) do
      if item_owner == owner then
        return false, 'cannot close non-empty owner ' .. tostring(owner) .. '; still owns ' .. tostring(item)
      end
    end
  end

  return true
end

function Ledger:prepare_commit_fragment(fragment, commit)
  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    commit:emit({ tag = 'ledger.move', item = mv.item, from = mv.from, to = mv.to })
  end
  for _, owner in ipairs(fragment.close_order or {}) do
    local cl = fragment.closes[owner]
    commit:emit({ tag = 'ledger.close', owner = cl.owner, reason = cl.reason })
  end
end

function Ledger:commit_fragment(fragment)
  for _, item in ipairs(fragment.move_order or {}) do
    local mv = fragment.moves[item]
    self.owners[item] = mv.to
  end
  for _, owner in ipairs(fragment.close_order or {}) do
    local cl = fragment.closes[owner]
    self.closed[owner] = cl.reason
  end
end

return Ledger
