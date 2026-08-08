-- A committed-world candidate. Its compact participant layout is private here.

local Journal = require('fibers.internal.kernel.journal')
local Proof = require('fibers.internal.proof')
local Effect = require('fibers.effect')

local Candidate = {}
Candidate.__index = Candidate
local EMPTY = {}
local NIL_EFFECT_KEY = {}

function Candidate.new(fields)
  return setmetatable(fields, Candidate)
end

function Candidate:count()
  return self.participant_count or #(self.participants or EMPTY)
end

function Candidate:participant(index)
  if self.participants then return self.participants[index] end
  if index == 1 then return self.participant_1 end
  if index == 2 then return self.participant_2 end
end

function Candidate:outcome(index, request)
  if index == 1 and self.outcome_1 ~= nil then return self.outcome_1 end
  if index == 2 and self.outcome_2 ~= nil then return self.outcome_2 end
  return self.outcomes and self.outcomes[request] or nil
end

function Candidate:is_fallback()
  return self.absence_gate ~= nil
end

function Candidate:membership_sensitive()
  return self.absence_gate and self.absence_gate.membership_sensitive == true or false
end

function Candidate:is_single(request)
  return self:count() == 1 and self:participant(1) == request
end

function Candidate:covers(members)
  local candidate_index = 1
  for member_index = 1, #members do
    local member = members[member_index]
    while candidate_index <= self:count() and self:participant(candidate_index).order < member.order do
      candidate_index = candidate_index + 1
    end
    if self:participant(candidate_index) ~= member then return false end
  end
  return true
end

function Candidate:discard(reason)
  local search = self._search
  if search then
    self._search = nil
    search:discard(reason)
  end
end

local function contract_error(runtime, phase, message)
  return runtime:_fatal('effect_contract_error', message, {
    phase = phase,
    committed = false,
    level = 0,
  })
end

local function effect_key(runtime, kind, payload)
  local key = runtime:_call_contract_in_phase('effect_key', 'effect_contract_error', kind.key, payload)
  if type(key) == 'number' and key ~= key then
    contract_error(runtime, 'effect_key',
      'effect kind ' .. tostring(kind.name) .. ' returned NaN as its key')
  end
  return key == nil and NIL_EFFECT_KEY or key
end

local function merge_effects(engine, source)
  local runtime = engine.runtime
  local by_kind, ordered = {}, {}
  for i = 1, #source do
    local effect, kind = source[i], source[i].kind
    local key = effect_key(runtime, kind, effect.payload)
    local bucket = by_kind[kind]
    if not bucket then bucket = {}; by_kind[kind] = bucket end
    local old = bucket[key]
    if old then
      local merged = runtime:_call_contract_in_phase(
        'effect_merge', 'effect_contract_error', kind.merge, old.payload, effect.payload
      )
      if Effect.is_rejection(merged) then
        return nil, Effect.rejection_reason(merged), true
      end
      if type(merged) ~= 'table' then
        contract_error(runtime, 'effect_merge',
          'effect kind ' .. tostring(kind.name)
            .. ' merge must return a payload table or Effect.reject(reason)')
      end
      old.payload = merged
    else
      local copy = { _fibers_effect = true, kind = kind, payload = effect.payload }
      bucket[key], ordered[#ordered + 1] = copy, copy
    end
  end
  return ordered
end

function Candidate:prepare(engine)
  if self.prepared_effects then return self.prepared_effects end
  local source = self.effects
  if not source or #source == 0 then self.prepared_effects = EMPTY; return EMPTY end
  local effects, err, rejected = merge_effects(engine, source)
  if not effects then return nil, err, rejected end
  local runtime, prepared = engine.runtime, {}
  for i = 1, #effects do
    local effect = effects[i]
    local value = runtime:_call_contract_in_phase(
      'effect_prepare', 'effect_contract_error', effect.kind.prepare, runtime, effect.payload
    )
    if Effect.is_rejection(value) then
      return nil, Effect.rejection_reason(value), true
    end
    if type(value) ~= 'table' or type(value.discharge) ~= 'function' then
      contract_error(runtime, 'effect_prepare',
        'effect kind ' .. tostring(effect.kind.name)
          .. ' prepare must return a record with discharge or Effect.reject(reason)')
    end
    prepared[#prepared + 1] = value
  end
  self.prepared_effects = prepared
  return prepared
end

function Candidate:validate(engine)
  for i = 1, self:count() do
    if not self:participant(i).pending then return false, 'participant-changed' end
  end
  local valid, reason = Journal.validate(self.observations)
  if not valid then return false, reason end
  local gate = self.absence_gate
  if gate then return Proof.valid(engine, gate.snapshot) end
  return true
end

function Candidate:settle(engine)
  local runtime, instrumentation = engine.runtime, engine.instrumentation
  if not self:validate(engine) then
    self:discard('stale-hit')
    return false, 'stale'
  end

  local prepared, err = self:prepare(engine)
  if not prepared then return false, err or 'effect-rejected' end

  local count, request1, request2 = self:count(), self:participant(1), self:participant(2)
  local outcome1 = request1 and self:outcome(1, request1) or nil
  local outcome2 = request2 and self:outcome(2, request2) or nil

  Journal.commit(self.writes)
  for location in pairs(self.writes or EMPTY) do Proof.touch_location(engine, location, 'commit') end
  engine.epoch = engine.epoch + 1
  if instrumentation then instrumentation:inc('commits') end

  if count <= 2 then engine:remove_small(count, request1, request2) else engine:remove(self.participants) end
  for i = 1, #prepared do
    local effect = prepared[i]
    runtime:_call_fatal_in_phase('effect_discharge', 'effect_error', true, effect.discharge, runtime, effect, nil)
  end
  if count <= 2 then
    if request1 then engine:resume(request1, outcome1) end
    if request2 then engine:resume(request2, outcome2) end
  else
    for i = 1, count do
      local request = self.participants[i]
      engine:resume(request, self.outcomes[request])
    end
  end
  self:discard('committed')
  return true
end

return Candidate
