-- A committed-world candidate.

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
  return #self.participants
end

function Candidate:participant(index)
  return self.participants[index]
end

function Candidate:outcome(index)
  return self.outcomes[index]
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
  runtime:_fatal('effect_contract_error', message, {
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
      if Effect.is_rejection(merged) then return nil end
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
  local effects = merge_effects(engine, source)
  if not effects then return nil end
  local runtime, prepared = engine.runtime, {}
  for i = 1, #effects do
    local effect = effects[i]
    local value = runtime:_call_contract_in_phase(
      'effect_prepare', 'effect_contract_error', effect.kind.prepare, runtime, effect.payload
    )
    if Effect.is_rejection(value) then return nil end
    if type(value) ~= 'table' or type(value.discharge) ~= 'function' then
      contract_error(runtime, 'effect_prepare',
        'effect kind ' .. tostring(effect.kind.name)
          .. ' prepare must return a record with discharge or Effect.reject(reason)')
    end
    prepared[#prepared + 1] = value
  end
  self.prepared_effects = prepared
  self.effects = nil
  return prepared
end

function Candidate:validate(engine)
  for i = 1, #self.participants do
    if not self.participants[i].pending then return false end
  end
  if not Journal.validate(self.observations) then return false end
  local gate = self.absence_gate
  if gate then return Proof.valid(engine, gate.snapshot) end
  return true
end

function Candidate:settle(engine)
  local runtime, instrumentation = engine.runtime, engine.instrumentation
  if not self:validate(engine) then
    self:discard('stale-hit')
    return false
  end

  local prepared = self.prepared_effects

  Journal.commit(self.writes)
  for location in pairs(self.writes or EMPTY) do Proof.touch_location(engine, location) end
  engine.epoch = engine.epoch + 1
  if instrumentation then instrumentation:inc('commits') end

  engine:remove(self.participants)
  for i = 1, #prepared do
    local effect = prepared[i]
    runtime:_call_fatal_in_phase('effect_discharge', 'effect_error', true, effect.discharge, runtime, effect, nil)
  end
  for i = 1, #self.participants do
    engine:resume(self.participants[i], self.outcomes[i])
  end
  self:discard('committed')
  return true
end

return Candidate
