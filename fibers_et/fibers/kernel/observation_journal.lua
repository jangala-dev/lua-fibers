-- Observation journal for bounded proof search.
--
-- The observation journal is the read side of transaction search.  Resource
-- journals record candidate writes; consequence logs record after-commit
-- obligations; the observation journal records mutable facts the search relied
-- on while producing candidates, waits, or absence proofs.
--
-- A bounded cursor may resume only while its observation journal is still
-- current.  The representation is deliberately small:
--   * object observations store a stamp and ask the object whether it is fresh;
--     versioned objects use their `version` field by default;
--   * time horizon observations say an observed future deadline has not arrived.

local ObservationJournal = {}
ObservationJournal.__index = ObservationJournal

local ContextMethods = {}

local function version_of(obj)
  if type(obj) ~= 'table' then return 0 end
  return obj.version or 0
end

local function context_journal(ctx, create)
  local journal = ctx.observations
  if journal then return journal end
  local owner = ctx.observation_owner
  if owner then
    journal = owner.observations
    if not journal and create then
      journal = ObservationJournal.new()
      owner.observations = journal
    end
    ctx.observations = journal
    return journal
  end
  if create then
    journal = ObservationJournal.new()
    ctx.observations = journal
    return journal
  end
  return nil
end

function ObservationJournal.new()
  return setmetatable({ observed = nil, until_time = nil }, ObservationJournal)
end

function ObservationJournal:watch(obj, stamp)
  if type(obj) ~= 'table' then return self end
  if stamp == nil then stamp = version_of(obj) end
  local observed = self.observed
  if not observed then observed = {}; self.observed = observed end
  local old = observed[obj]
  if old == nil then
    observed[obj] = stamp
  elseif old ~= stamp then
    -- A single paused search observed the same object at two different stamps.
    -- Retaining the first stamp makes the cursor non-current once validation is
    -- attempted.  In ordinary use host/resource mutation happens between search
    -- steps rather than during evaluation.
  end
  return self
end

function ObservationJournal:observe_version(obj, version)
  version = version
  if version == nil then version = version_of(obj) end
  self:watch(obj, version)
  return version
end

function ObservationJournal:before(deadline)
  if type(deadline) ~= 'number' then return self end
  if self.until_time == nil or deadline < self.until_time then self.until_time = deadline end
  return self
end

function ObservationJournal:is_current(rt)
  local observed = self.observed
  if observed then
    for obj, stamp in pairs(observed) do
      local fresh = obj and obj.fresh
      if type(fresh) == 'function' then
        if not fresh(obj, stamp, rt) then return false end
      elseif version_of(obj) ~= stamp then
        return false
      end
    end
  end

  local deadline = self.until_time
  if deadline ~= nil then
    local now = 0
    if rt and rt.now then now = rt:now() end
    if now >= deadline then return false end
  end

  return true
end

function ObservationJournal:summary()
  local n = 0
  if self.observed then for _ in pairs(self.observed) do n = n + 1 end end
  return { observations = n, version_observations = n, until_time = self.until_time }
end

function ContextMethods:observe_version(obj, version)
  if version == nil then version = version_of(obj) end
  if type(obj) ~= 'table' then return version end
  local journal = context_journal(self, true)
  local observed = journal.observed
  if not observed then observed = {}; journal.observed = observed end
  local old = observed[obj]
  if old == nil then observed[obj] = version end
  return version
end

function ContextMethods:observe(obj, ...)
  if type(obj) == 'table' and type(obj.snapshot) == 'function' and type(obj.fresh) == 'function' then
    local stamp, view = obj:snapshot(self.rt, ...)
    self:observe_version(obj, stamp)
    return view, stamp
  end
  return self:observe_version(obj), obj
end

function ContextMethods:before(deadline)
  if type(deadline) ~= 'number' then return deadline end
  local journal = context_journal(self, true)
  if journal.until_time == nil or deadline < journal.until_time then journal.until_time = deadline end
  return deadline
end

function ContextMethods:now()
  local rt = self.rt
  if rt and rt.now then return rt:now() end
  return 0
end

function ObservationJournal.attach(ctx, owner_or_journal)
  ctx = ctx or {}
  if owner_or_journal and getmetatable(owner_or_journal) == ObservationJournal then
    ctx.observations = owner_or_journal
  else
    ctx.observation_owner = owner_or_journal
    ctx.observations = owner_or_journal and owner_or_journal.observations or nil
  end
  ctx.observe = ContextMethods.observe
  ctx.observe_version = ContextMethods.observe_version
  ctx.before = ContextMethods.before
  ctx.now = ContextMethods.now
  return ctx
end

return ObservationJournal
