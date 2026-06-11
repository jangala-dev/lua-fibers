-- Typed wait interests.
--
-- A wait interest says: this operation cannot commit now, but the host/runtime
-- may be able to make progress when the named external condition changes.  It
-- is deliberately separate from a consequence, which says: this transaction has
-- committed and the runtime must now do some work.

local Wait = {}

local next_id = 0

local function stable_source_id(source)
  if source == nil then return nil end
  if type(source) ~= 'table' then return tostring(source) end
  if source._fibers_id then return tostring(source._fibers_id) end
  next_id = next_id + 1
  source._fibers_wait_id = source._fibers_wait_id or ('wait-source-' .. tostring(next_id))
  return source._fibers_wait_id
end

local function make(kind, key, fields)
  fields = fields or {}
  fields.kind = kind
  fields.key = key
  fields.id = tostring(kind) .. ':' .. tostring(key)
  fields._fibers_wait = true
  return fields
end

function Wait.is_wait(x)
  return type(x) == 'table' and x._fibers_wait == true
end

function Wait.time(deadline, source)
  return make('time', tostring(deadline), {
    deadline = deadline,
    source = source,
    primitive = 'sleep',
  })
end

function Wait.source(source, interest, detail)
  local sid = stable_source_id(source)
  local key = tostring(sid) .. ':' .. tostring(interest or 'ready')
  detail = detail or {}
  detail.source = source
  detail.interest = interest or 'ready'
  detail.primitive = 'source'
  return make('source', key, detail)
end

function Wait.resource(kind, key, source, detail)
  return make(kind, key, {
    source = source,
    detail = detail,
    primitive = 'resource',
  })
end

-- Merge interests by typed id for public reporting.  The solver already
-- preserves object identity; hosts usually want a stable keyed view.
function Wait.merge(list)
  local out, seen = {}, {}
  for i = 1, #(list or {}) do
    local w = list[i]
    local id = Wait.is_wait(w) and w.id or tostring(w)
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = w
    end
  end
  return out
end

function Wait.summarise(list)
  local out = {}
  for i = 1, #(list or {}) do
    local w = list[i]
    if Wait.is_wait(w) then
      out[#out + 1] = {
        kind = w.kind,
        key = w.key,
        id = w.id,
        deadline = w.deadline,
        mode = w.mode,
        interest = w.interest,
      }
    else
      out[#out + 1] = w
    end
  end
  return out
end

return Wait
