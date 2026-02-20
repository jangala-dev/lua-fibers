-- fibers/choice_gate.lua
--
-- Helpers for ctx.select_top / sel.winner arbitration.
--
-- Conventions:
--   * sel == nil  => not in a choice; proceed freely.
--   * sel.winner  => nil until some arm claims; once set, only that node proceeds.

local M = {}

function M.sel_from_ctx(ctx)
  return ctx.select_top
end

-- Can this node make progress in poll (including attempting to claim)?
function M.can_proceed(sel, node)
  if not sel then return true end
  local w = sel.winner
  return (w == nil) or (w == node)
end

-- Attempt to claim the selection for this node.
-- Returns true if this node is (now) the winner, false otherwise.
function M.claim(sel, node)
  if not sel then return true end
  local w = sel.winner
  if w == nil then
    sel.winner = node
    return true
  end
  return w == node
end

-- Can this node report "ready" right now?
-- This is stricter than can_proceed: if sel exists and no-one has claimed yet,
-- reporting ready would be premature.
function M.can_report_ready(sel, node)
  if not sel then return true end
  return sel.winner == node
end

function M.is_winner(sel, node)
  return sel and sel.winner == node or false
end

return M
