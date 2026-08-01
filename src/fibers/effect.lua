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
local function spawn_key(payload)
  return payload.id or payload.owner or payload.name or payload.fn
end

SpawnKind = EffectKind.new({
  name = 'spawn',
  key = spawn_key,
  merge = function()
    return nil, { kind = 'effect_conflict', message = 'duplicate spawn effect' }
  end,
  prepare = function(rt, payload)
    local owner = payload.owner
    if owner ~= nil then
      if type(owner) ~= 'table' or type(owner._take_spawn_body) ~= 'function' then
        return nil, 'owned spawn effect requires a Task owner'
      end
      local life = owner._lifetime
      if type(life) ~= 'table' or type(life.body) ~= 'function' then
        return nil, 'owned spawn effect requires a dormant task body'
      end
      if life.runtime ~= nil and life.runtime ~= rt then
        return nil, 'spawn Task belongs to another runtime'
      end
    elseif type(payload.fn) ~= 'function' then
      return nil, 'spawn effect requires a function or Task owner'
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
        return discharge_rt:_spawn_committed(fn, p.name, p.scope)
      end,
    }
  end,
})

function Effect.spawn(fn, name, id, scope, owner)
  local payload = { fn = fn, name = name, scope = scope, owner = owner }
  payload.id = id or owner or payload
  return Effect.of(SpawnKind, payload)
end

Effect.InterruptKind = InterruptKind
Effect.SpawnKind = SpawnKind
Effect.EffectKind = EffectKind

return Effect
