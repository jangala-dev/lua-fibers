local Engine = require('fibers.kernel.solver.engine')

-- Resumable algebra cursor -------------------------------------------------
--
-- A cursor stores the proof-search engine state plus the certificate information
-- needed to resume a bounded search safely.  It does not commit resources,
-- discharge effects, mutate nack states or resume fibres.  Commit authority
-- remains with Runtime/CommitPlan.
local Cursor = {}
Cursor.__index = Cursor

function Cursor.new(rt, waiting, opts)
  local c = setmetatable({
    rt = rt,
    epoch = rt._epoch or 0,
    waiting = {},
    requests = {},
    engine = Engine.new(rt, waiting, opts),
  }, Cursor)
  for i = 1, #waiting do
    c.waiting[i] = waiting[i]
    c.requests[i] = waiting[i].waiting
  end
  return c
end

function Cursor:is_valid(rt, waiting)
  if self.rt ~= rt or self.epoch ~= (rt._epoch or 0) then return false end
  if #waiting ~= #self.waiting then return false end
  for i = 1, #waiting do
    if waiting[i] ~= self.waiting[i] then return false end
    if waiting[i].waiting ~= self.requests[i] then return false end
  end
  local certificate = self.engine and self.engine.certificate
  if certificate and not certificate:is_current(rt) then return false end
  return true
end

function Cursor:resume(max_work)
  return self.engine:resume(max_work)
end

function Cursor:stats_snapshot()
  return self.engine:stats_snapshot()
end

return Cursor
