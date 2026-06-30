-- Result of asking a resource leaf whether it can participate now.
-- Branching belongs to option algebra; a leaf is ready with one proposal,
-- waits for one future interest, opens a proof premise, or is blocked in the current world.
local Result = {}

local BLOCKED = { status = 'blocked' }
Result.BLOCKED = BLOCKED

function Result.ready(proposal)
  if proposal == nil then return BLOCKED end
  return { status = 'ready', proposal = proposal }
end

function Result.wait(interest)
  if interest == nil then return BLOCKED end
  return { status = 'wait', wait = interest }
end

function Result.premise(request, wait)
  if request == nil then return BLOCKED end
  return { status = 'premise', premise = request, wait = wait }
end

function Result.blocked()
  return BLOCKED
end

Result.none = Result.blocked

function Result.from(r)
  if type(r) == 'table' and r.status then return r end
  return BLOCKED
end

return Result
