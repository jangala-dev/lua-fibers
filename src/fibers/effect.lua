-- Public typed committed-world effects.
--
-- Effects are runtime-owned obligations carried by candidate worlds and
-- discharged iff the selected world commits.  Effect callbacks obey a strict
-- protocol:
--
--   * key and merge are speculative, deterministic and replayable;
--   * prepare is pure, deterministic, non-yielding and replayable;
--   * discharge runs only after resource state has committed and may perform the
--     irreversible host action represented by the prepared record.
--
-- prepare must not reserve capacity, mutate host state, deliver external facts,
-- spawn, perform, yield or otherwise require rollback. It returns either an
-- explicit Effect.reject(reason) value or a prepared record containing a
-- discharge function. Returning nil or a malformed record is an authoring
-- contract error, not semantic candidate rejection. A refusal must depend only
-- on the payload, captured
-- runtime configuration or managed facts already represented by the candidate.
--
-- Effect identity is the pair (EffectKind object, raw Lua key).  Lua types and
-- object identity are preserved: 1 differs from "1", and distinct tables are
-- distinct keys.  nil is supported; NaN is rejected because it has no stable
-- table-key identity.

local Contract = require('fibers.internal.contract')

local EffectKind = (function()
  local EffectKind = {}
  EffectKind.__index = EffectKind


  local KIND_OPTIONS = {
    name = true,
    key = true,
    merge = true,
    prepare = true,
    validate_payload = true,
  }

  local function require_function(spec, name)
    if type(spec[name]) ~= 'function' then
      error('Effect.kind requires ' .. name .. ' to be a function', 3)
    end
  end

  function EffectKind.new(spec)
    spec = Contract.options(spec, KIND_OPTIONS, 'Effect.kind specification', 2)
    Contract.non_empty_string(spec.name, 'Effect.kind name', 2)
    require_function(spec, 'key')
    require_function(spec, 'merge')
    require_function(spec, 'prepare')
    Contract.optional_function(spec.validate_payload, 'Effect.kind validate_payload', 2)

    local kind = {
      _fibers_effect_kind = true,
      name = spec.name,
      key = spec.key,
      merge = spec.merge,
      prepare = spec.prepare,
      validate_payload = spec.validate_payload,
    }

    return setmetatable(kind, EffectKind)
  end

  function EffectKind:of(payload)
    if type(payload) ~= 'table' then
      error(self.name .. ' effect payload must be a table', 2)
    end

    if self.validate_payload then
      local ok, err = self.validate_payload(self, payload)
      if ok ~= true then
        if err == nil then
          error(self.name .. ' validate_payload must return true or false/nil plus an error', 2)
        end
        error(type(err) == 'table' and (err.message or err.kind) or tostring(err), 2)
      end
    end

    return {
      _fibers_effect = true,
      kind = self,
      payload = payload,
    }
  end

  function EffectKind.is_kind(x)
    return type(x) == 'table' and x._fibers_effect_kind == true
  end

  function EffectKind.is_effect(x)
    return type(x) == 'table' and x._fibers_effect == true and EffectKind.is_kind(x.kind)
  end

  return EffectKind
end)()

local Effect = {}

local Rejection = {}
Rejection.__index = Rejection

-- Explicit semantic refusal from merge/prepare. Trusted effect callbacks must
-- use this value when a well-formed candidate world is inadmissible. Ordinary
-- nil returns are reserved for authoring mistakes so they cannot silently alter
-- choice/or_else semantics.
function Effect.reject(reason)
  if type(reason) ~= 'table' then
    error('Effect.reject requires a structured reason table', 2)
  end
  Contract.non_empty_string(reason.kind, 'Effect.reject reason.kind', 2)
  return setmetatable({ _fibers_effect_rejection = true, reason = reason }, Rejection)
end

function Effect.is_rejection(value)
  return type(value) == 'table' and getmetatable(value) == Rejection
end

function Effect.rejection_reason(value)
  return Effect.is_rejection(value) and value.reason or nil
end


function Effect.kind(spec)
  return EffectKind.new(spec)
end

Effect.is_kind = EffectKind.is_kind
Effect.is_effect = EffectKind.is_effect

function Effect.of(kind, payload)
  if not EffectKind.is_kind(kind) then
    error('Effect.of expects an Effect kind', 2)
  end
  return kind:of(payload)
end

local InterruptKind
local function interrupt_key(payload)
  local token = payload.token
  return payload.token
end

InterruptKind = EffectKind.new({
  name = 'interrupt',
  key = interrupt_key,
  merge = function(a, b)
    return { token = a.token, reason = a.reason ~= nil and a.reason or b.reason }
  end,
  prepare = function(_rt, payload)
    if type(payload.token) ~= 'table' or not payload.token._fibers_interrupt then
      error('interrupt effect requires an interrupt token', 0)
    end
    return {
      kind = InterruptKind,
      key = interrupt_key(payload),
      payload = payload,
      discharge = function(rt, entry, _log)
        if not rt._discharge_interrupt then
          error('runtime does not support committed interrupt', 2)
        end
        return rt:_discharge_interrupt(entry.payload.token, entry.payload.reason)
      end,
    }
  end,
})

function Effect.interrupt(token, reason)
  return Effect.of(InterruptKind, { token = token, reason = reason })
end

local SpawnKind
local function spawn_key(payload)
  return payload.id or payload.owner or payload.fn
end

SpawnKind = EffectKind.new({
  name = 'spawn',
  key = spawn_key,
  merge = function()
    return Effect.reject({ kind = 'effect_conflict', message = 'duplicate spawn effect' })
  end,
  prepare = function(rt, payload)
    local owner = payload.owner
    if owner ~= nil then
      if type(owner) ~= 'table' or type(owner._take_spawn_body) ~= 'function' then
        error('owned spawn effect requires a Task owner', 0)
      end
      local life = owner._lifetime
      if type(life) ~= 'table' or type(life._body) ~= 'function' then
        error('owned spawn effect requires a dormant task body', 0)
      end
      if life._runtime ~= nil and life._runtime ~= rt then
        error('spawn Task belongs to another runtime', 0)
      end
    elseif type(payload.fn) ~= 'function' then
      error('spawn effect requires a function or Task owner', 0)
    end
    return {
      kind = SpawnKind,
      key = spawn_key(payload),
      payload = payload,
      discharge = function(discharge_rt, entry, _log)
        if not discharge_rt._spawn_committed then
          error('runtime does not support committed spawn', 2)
        end
        local p = entry.payload
        local fn = p.fn
        if p.owner ~= nil then
          fn = p.owner:_take_spawn_body(discharge_rt)
        end
        return discharge_rt:_spawn_committed(fn, p.scope, p.owner)
      end,
    }
  end,
})

function Effect.spawn(fn, id, scope, owner)
  local payload = { fn = fn, scope = scope, owner = owner }
  payload.id = id or owner or payload
  return Effect.of(SpawnKind, payload)
end

Effect.InterruptKind = InterruptKind
Effect.SpawnKind = SpawnKind
Effect.EffectKind = EffectKind

return Effect
