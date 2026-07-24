local Effect = require('fibers.effect')

local M = {}

M.TagKind = Effect.kind({
  name = 'test.tag',
  key = function(payload)
    return payload.tag or payload.kind
  end,
  merge = function(a, b)
    local at, bt = a.tag or a.kind, b.tag or b.kind
    if at ~= bt then
      return nil, { kind = 'effect_conflict', message = 'tag key mismatch' }
    end
    if a.value ~= nil and b.value ~= nil and a.value ~= b.value then
      return nil, { kind = 'effect_conflict', message = 'tag value conflict' }
    end
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = M.TagKind,
      key = payload.tag or payload.kind,
      payload = payload,
      discharge = function(rt, _entry, _log)
        local host = rt.host or {}
        if host.test_tag then
          return host.test_tag(payload.tag or payload.kind, payload)
        end
      end,
    }
  end,
})

M.ConflictKind = Effect.kind({
  name = 'test.conflict',
  key = function(_payload)
    return 'same'
  end,
  merge = function(_a, _b)
    return nil, { kind = 'effect_conflict', message = 'test conflict' }
  end,
  prepare = function(_rt, payload)
    return {
      kind = M.ConflictKind,
      key = 'same',
      payload = payload,
      discharge = function() end,
    }
  end,
})

M.PrepareRefuseKind = Effect.kind({
  name = 'test.prepare_refuse',
  key = function(_payload)
    return 'refuse'
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function()
    return nil, { kind = 'effect_prepare_refused', message = 'refused by test kind' }
  end,
})

M.DischargeFatalKind = Effect.kind({
  name = 'test.discharge_fatal',
  key = function(_payload)
    return 'fatal'
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = M.DischargeFatalKind,
      key = 'fatal',
      payload = payload,
      discharge = function()
        error('discharge exploded')
      end,
    }
  end,
})

function M.tag(name, fields)
  fields = fields or {}
  fields.tag = fields.tag or name
  local c, err = M.TagKind:of(fields)
  if not c then
    error(err and err.message or tostring(err), 2)
  end
  return c
end

function M.kind(name)
  return M.tag(name, { kind = name })
end

function M.conflict(label)
  local c, err = M.ConflictKind:of({ label = label })
  if not c then
    error(err and err.message or tostring(err), 2)
  end
  return c
end

function M.prepare_refuse()
  local c, err = M.PrepareRefuseKind:of({})
  if not c then
    error(err and err.message or tostring(err), 2)
  end
  return c
end

function M.discharge_fatal()
  local c, err = M.DischargeFatalKind:of({})
  if not c then
    error(err and err.message or tostring(err), 2)
  end
  return c
end

return M
