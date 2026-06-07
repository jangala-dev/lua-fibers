-- Public typed after-commit effects.
--
-- Effects are the public form of transaction consequences: runtime-owned
-- obligations that are published iff the selected world commits.  The built-in
-- effects are deliberately small: wake is a level-triggered nudge, and spawn
-- starts a fibre after its admission has committed.

local Op = require('fibers.op')
local ConsequenceKind = require('fibers.consequence.kind')

local Effect = {}

function Effect.kind(spec)
  return ConsequenceKind.new(spec)
end

Effect.new_kind = Effect.kind
Effect.is_kind = ConsequenceKind.is_kind
Effect.is_effect = ConsequenceKind.is_consequence
Effect.is_consequence = ConsequenceKind.is_consequence

function Effect.of(kind, payload)
  if not ConsequenceKind.is_kind(kind) then error('Effect.of expects an Effect kind', 2) end
  local e, err = kind:of(payload)
  if not e then error(err and (err.message or tostring(err)) or 'invalid effect payload', 2) end
  return e
end

function Effect.after_commit(effect)
  return Op.emit(effect)
end

Effect.emit = Effect.after_commit

local WakeKind
local function wake_key(payload)
  return payload.id or payload.key or tostring(payload.kind) .. ':' .. tostring(payload.source)
end

WakeKind = ConsequenceKind.new {
  name = 'wake',
  order = 50,
  key = wake_key,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = WakeKind,
      key = wake_key(payload),
      payload = payload,
      publish = function(rt, entry, log)
        if rt._note_wake then rt:_note_wake(entry.payload, log) end
        local host = rt.host or {}
        local services = rt.services or {}
        local wake = host.wake or services.wake
        if wake then return wake(entry.payload, rt, log) end
      end,
    }
  end,
}

function Effect.wake(kind, key, detail)
  return Effect.of(WakeKind, {
    kind = kind,
    key = key,
    id = tostring(kind) .. ':' .. tostring(key),
    detail = detail,
  })
end

local SpawnKind
local next_spawn = 0
local function spawn_key(payload)
  return payload.id or payload.name or tostring(payload.fn)
end

SpawnKind = ConsequenceKind.new {
  name = 'spawn',
  order = 100,
  key = spawn_key,
  merge = function()
    return nil, { kind = 'effect_conflict', message = 'duplicate spawn effect' }
  end,
  prepare = function(_rt, payload)
    if type(payload.fn) ~= 'function' then return nil, 'spawn effect requires a function' end
    return {
      kind = SpawnKind,
      key = spawn_key(payload),
      payload = payload,
      publish = function(rt, entry, _log)
        if not rt._spawn_committed then error('runtime does not support committed spawn', 2) end
        return rt:_spawn_committed(entry.payload.fn, entry.payload.name)
      end,
    }
  end,
}

function Effect.spawn(fn, name, id)
  next_spawn = next_spawn + 1
  return Effect.of(SpawnKind, { fn = fn, name = name, id = id or ('spawn-' .. tostring(next_spawn)) })
end

Effect.WakeKind = WakeKind
Effect.SpawnKind = SpawnKind
Effect.ConsequenceKind = ConsequenceKind

return Effect
