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




local InterruptKind
local function interrupt_key(payload)
  local token = payload.token
  return token and (token._fibers_id or token.name) or tostring(token)
end

InterruptKind = ConsequenceKind.new {
  name = 'interrupt',
  order = 55,
  key = interrupt_key,
  merge = function(a, b)
    if a.reason == nil then a.reason = b.reason end
    return a
  end,
  prepare = function(_rt, payload)
    if type(payload.token) ~= 'table' or not payload.token._fibers_interrupt then
      return nil, 'interrupt effect requires an interrupt token'
    end
    return {
      kind = InterruptKind,
      key = interrupt_key(payload),
      payload = payload,
      publish = function(rt, entry, _log)
        if rt._publish_interrupt then return rt:_publish_interrupt(entry.payload.token, entry.payload.reason) end
        return entry.payload.token:raise(entry.payload.reason)
      end,
    }
  end,
}

function Effect.interrupt(token, reason)
  return Effect.of(InterruptKind, { token = token, reason = reason })
end

local LifetimeKind
local function lifetime_key(payload)
  local typ = payload.type or payload.event or 'lifetime'
  local item = payload.item
  local item_id = item and (item._fibers_id or item.name) or payload.item_id or ''
  local from = payload.from
  local to = payload.to or payload.region
  local from_id = from and (from._fibers_id or from.name) or payload.from_id or ''
  local to_id = to and (to._fibers_id or to.name) or payload.to_id or ''
  return tostring(typ) .. ':' .. tostring(item_id) .. ':' .. tostring(from_id) .. ':' .. tostring(to_id)
end

LifetimeKind = ConsequenceKind.new {
  name = 'lifetime',
  order = 60,
  key = lifetime_key,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = LifetimeKind,
      key = lifetime_key(payload),
      payload = payload,
      publish = function(rt, entry, log)
        rt.published_lifetime = rt.published_lifetime or {}
        rt.published_lifetime[#rt.published_lifetime + 1] = entry.payload
        local function publish_source(src)
          if type(src) == 'table' and type(src.emit) == 'function' then src:emit(entry.payload) end
        end
        publish_source(entry.payload.source)
        local sources = entry.payload.sources
        if type(sources) == 'table' then for i = 1, #sources do publish_source(sources[i]) end end
        local host = rt.host or {}
        local services = rt.services or {}
        local publish = host.lifetime or services.lifetime
        if publish then return publish(entry.payload, rt, log) end
      end,
    }
  end,
}

function Effect.lifetime(event)
  if type(event) ~= 'table' then error('Effect.lifetime expects an event table', 2) end
  return Effect.of(LifetimeKind, event)
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
        return rt:_spawn_committed(entry.payload.fn, entry.payload.name, entry.payload.frame)
      end,
    }
  end,
}

function Effect.spawn(fn, name, id, frame)
  next_spawn = next_spawn + 1
  return Effect.of(SpawnKind, { fn = fn, name = name, id = id or ('spawn-' .. tostring(next_spawn)), frame = frame })
end

Effect.WakeKind = WakeKind
Effect.InterruptKind = InterruptKind
Effect.LifetimeKind = LifetimeKind
Effect.SpawnKind = SpawnKind
Effect.ConsequenceKind = ConsequenceKind

return Effect
