-- Semantically inert human-readable labels for Fibers values.
--
-- Stable runtime identity remains in `_fibers_id`. A label is optional,
-- non-unique diagnostic metadata and must never participate in matching,
-- ownership, authority or equality.

local Label = {}

local function validate(value, level)
  if value ~= nil and type(value) ~= 'string' then
    error('label expects a string or nil', level or 3)
  end
  if value == '' then
    error('label expects a non-empty string or nil', level or 3)
  end
  return value
end

local function method(self, ...)
  if select('#', ...) == 0 then
    return rawget(self, '_fibers_label')
  end
  local value = select(1, ...)
  validate(value, 3)
  rawset(self, '_fibers_label', value)
  return self
end

function Label.attach(value, initial)
  if type(value) ~= 'table' then
    error('label attachment expects a table value', 2)
  end
  validate(initial, 3)
  if initial ~= nil then
    rawset(value, '_fibers_label', initial)
  end
  if rawget(value, 'label') == nil then
    rawset(value, 'label', method)
  end
  return value
end

function Label.set(value, label, level)
  if type(value) ~= 'table' then
    error('label expects a Fibers value', level or 3)
  end
  validate(label, (level or 2) + 1)
  rawset(value, '_fibers_label', label)
  return value
end

function Label.child(value, subject, suffix)
  if type(value) ~= 'table' then
    error('label child expects a table value', 2)
  end
  if type(subject) ~= 'table' then
    error('label child expects a table subject', 2)
  end
  if suffix ~= nil and (type(suffix) ~= 'string' or suffix == '') then
    error('label child suffix expects a non-empty string or nil', 2)
  end
  -- Structural children derive their default description from the parent. A
  -- later explicit :label(...) on the child still takes precedence.
  rawset(value, '_fibers_label', nil)
  rawset(value, '_fibers_label_subject', subject)
  rawset(value, '_fibers_label_suffix', suffix)
  return value
end


local function proxy_method(self, ...)
  local subject = rawget(self, '_fibers_label_subject')
  if type(subject) ~= 'table' then
    error('label proxy has no subject', 2)
  end
  if select('#', ...) == 0 then
    return Label.get(subject)
  end
  Label.set(subject, select(1, ...), 3)
  return self
end

function Label.proxy(value, subject)
  if type(value) ~= 'table' or type(subject) ~= 'table' then
    error('label proxy expects table values', 2)
  end
  rawset(value, '_fibers_label_subject', subject)
  rawset(value, 'label', proxy_method)
  return value
end

function Label.get(value)
  if type(value) ~= 'table' then return nil end
  return rawget(value, '_fibers_label')
end

function Label.describe(value, fallback)
  if type(value) ~= 'table' then
    return fallback or tostring(value)
  end
  local label = rawget(value, '_fibers_label')
  if label ~= nil then return label end
  local lifetime = rawget(value, '_lifetime')
  if type(lifetime) == 'table' and lifetime ~= value then
    local described = Label.describe(lifetime)
    if described ~= nil then return described end
  end
  local subject = rawget(value, '_fibers_label_subject')
  if subject ~= nil and subject ~= value then
    local described = Label.describe(subject)
    if described ~= nil then
      local suffix = rawget(value, '_fibers_label_suffix')
      if suffix ~= nil then return described .. ':' .. suffix end
      return described
    end
  end
  local id = rawget(value, '_fibers_id')
  if id ~= nil then return tostring(id) end
  return fallback
end

return Label
