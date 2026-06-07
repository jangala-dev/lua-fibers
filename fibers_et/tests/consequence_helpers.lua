local ConsequenceKind = require('fibers.consequence.kind')

local M = {}

M.TagKind = ConsequenceKind.new {
  name = 'test.tag',
  order = 900,
  key = function(payload) return payload.tag or payload.kind end,
  merge = function(a, b)
    local at, bt = a.tag or a.kind, b.tag or b.kind
    if at ~= bt then
      return nil, { kind = 'consequence_conflict', message = 'tag key mismatch' }
    end
    if a.value ~= nil and b.value ~= nil and a.value ~= b.value then
      return nil, { kind = 'consequence_conflict', message = 'tag value conflict' }
    end
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = M.TagKind,
      key = payload.tag or payload.kind,
      payload = payload,
      publish = function(rt, _entry, _log)
        if rt.services and rt.services.test_tag then
          return rt.services.test_tag(payload.tag or payload.kind, payload)
        end
      end,
    }
  end,
}

M.ConflictKind = ConsequenceKind.new {
  name = 'test.conflict',
  order = 901,
  key = function(_payload) return 'same' end,
  merge = function(_a, _b)
    return nil, { kind = 'consequence_conflict', message = 'test conflict' }
  end,
  prepare = function(_rt, payload)
    return {
      kind = M.ConflictKind,
      key = 'same',
      payload = payload,
      publish = function() end,
    }
  end,
}

M.PrepareRefuseKind = ConsequenceKind.new {
  name = 'test.prepare_refuse',
  order = 902,
  key = function(_payload) return 'refuse' end,
  merge = function(a, _b) return a end,
  prepare = function()
    return nil, { kind = 'consequence_prepare_refused', message = 'refused by test kind' }
  end,
}

M.PublishFatalKind = ConsequenceKind.new {
  name = 'test.publish_fatal',
  order = 903,
  key = function(_payload) return 'fatal' end,
  merge = function(a, _b) return a end,
  prepare = function(_rt, payload)
    return {
      kind = M.PublishFatalKind,
      key = 'fatal',
      payload = payload,
      publish = function()
        error('publish exploded')
      end,
    }
  end,
}

function M.tag(name, fields)
  fields = fields or {}
  fields.tag = fields.tag or name
  local c, err = M.TagKind:of(fields)
  if not c then error(err and err.message or tostring(err), 2) end
  return c
end

function M.kind(name)
  return M.tag(name, { kind = name })
end

function M.conflict(label)
  local c, err = M.ConflictKind:of({ label = label })
  if not c then error(err and err.message or tostring(err), 2) end
  return c
end

function M.prepare_refuse()
  local c, err = M.PrepareRefuseKind:of({})
  if not c then error(err and err.message or tostring(err), 2) end
  return c
end

function M.publish_fatal()
  local c, err = M.PublishFatalKind:of({})
  if not c then error(err and err.message or tostring(err), 2) end
  return c
end

return M
