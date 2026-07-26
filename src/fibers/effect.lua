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
-- spawn, perform, yield or otherwise require rollback.  It may return nil plus a
-- structured reason to reject the candidate, or a prepared record containing a
-- discharge function.  A refusal must depend only on the payload, captured
-- runtime configuration or managed facts already represented by the candidate.
--
-- Effect identity is the pair (EffectKind object, raw Lua key).  Lua types and
-- object identity are preserved: 1 differs from "1", and distinct tables are
-- distinct keys.  nil is supported; NaN is rejected because it has no stable
-- table-key identity.

local EffectKind = (function()
  local EffectKind = {}
  EffectKind.__index = EffectKind

  local next_kind_id = 0

  local function assert_field(spec, name, ty)
    if type(spec[name]) ~= ty then
      error('EffectKind.new requires ' .. name .. ' :: ' .. ty, 3)
    end
  end

  function EffectKind.new(spec)
    assert(type(spec) == 'table', 'EffectKind.new expects a spec table')
    assert_field(spec, 'name', 'string')
    assert_field(spec, 'key', 'function')
    assert_field(spec, 'merge', 'function')
    assert_field(spec, 'prepare', 'function')

    next_kind_id = next_kind_id + 1
    local kind = {
      _fibers_effect_kind = true,
      _fibers_kind_id = next_kind_id,
      name = spec.name,
      key = spec.key,
      merge = spec.merge,
      prepare = spec.prepare,
      failure = spec.failure or 'fatal',
      validate_payload = spec.validate_payload,
    }

    if kind.failure ~= 'fatal' then
      error('unsupported effect failure policy: ' .. tostring(kind.failure), 2)
    end

    return setmetatable(kind, EffectKind)
  end

  function EffectKind:of(payload)
    if type(payload) ~= 'table' then
      return nil, { kind = 'invalid_effect_payload', message = self.name .. ' payload must be a table' }
    end

    if self.validate_payload then
      local ok, err = self.validate_payload(self, payload)
      if not ok then
        return nil, err
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

local function shallow_copy(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = v
  end
  return out
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
  local e, err = kind:of(payload)
  if not e then
    error(err and (err.message or tostring(err)) or 'invalid effect payload', 2)
  end
  return e
end

local InterruptKind
local function interrupt_key(payload)
  local token = payload.token
  return token and (token._fibers_id or token.name) or tostring(token)
end

InterruptKind = EffectKind.new({
  name = 'interrupt',
  key = interrupt_key,
  merge = function(a, b)
    return { token = a.token, reason = a.reason ~= nil and a.reason or b.reason }
  end,
  prepare = function(_rt, payload)
    if type(payload.token) ~= 'table' or not payload.token._fibers_interrupt then
      return nil, 'interrupt effect requires an interrupt token'
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
local next_spawn = 0
local function spawn_key(payload)
  return payload.id or payload.name or tostring(payload.fn)
end

SpawnKind = EffectKind.new({
  name = 'spawn',
  key = spawn_key,
  merge = function()
    return nil, { kind = 'effect_conflict', message = 'duplicate spawn effect' }
  end,
  prepare = function(_rt, payload)
    if type(payload.fn) ~= 'function' then
      return nil, 'spawn effect requires a function'
    end
    return {
      kind = SpawnKind,
      key = spawn_key(payload),
      payload = payload,
      discharge = function(rt, entry, _log)
        if not rt._spawn_committed then
          error('runtime does not support committed spawn', 2)
        end
        local owner = entry.payload.owner
        if owner then
          owner.fn = nil
          owner.scope = nil
        end
        return rt:_spawn_committed(entry.payload.fn, entry.payload.name, entry.payload.scope)
      end,
    }
  end,
})

function Effect.spawn(fn, name, id, scope, owner)
  next_spawn = next_spawn + 1
  return Effect.of(SpawnKind, {
    fn = fn,
    name = name,
    id = id or ('spawn-' .. tostring(next_spawn)),
    scope = scope,
    owner = owner,
  })
end

Effect.InterruptKind = InterruptKind
Effect.SpawnKind = SpawnKind
Effect.EffectKind = EffectKind

return Effect
