local core = require('etfcore')
local Op = core.Op

-- --------------------------------------------------------------------------
-- Log resource: append-only transactional record.
-- --------------------------------------------------------------------------

local Log = {}
Log.__index = Log

local function copy_list(xs)
  local ys = {}
  if xs then for i = 1, #xs do ys[i] = xs[i] end end
  return ys
end

local function copy_fragment(f)
  return { base_version = f.base_version, appends = copy_list(f.appends) }
end

function Log.new(records, name)
  return setmetatable({ records = copy_list(records or {}), version = 0, name = name or 'log' }, Log)
end

function Log:append_op(record)
  return Op.access(self, { tag = 'append', record = record })
end

function Log:read_from_op(offset)
  return Op.access(self, { tag = 'read_from', offset = offset or 1 })
end

function Log:next_offset_op()
  return Op.access(self, { tag = 'next_offset' })
end

function Log:empty_fragment()
  return { base_version = self.version, appends = {} }
end

local function view_records(self, view)
  local out = copy_list(self.records)
  for i = 1, #(view.appends or {}) do out[#out + 1] = view.appends[i] end
  return out
end

function Log:step_fragment_with_view(view_fragment, local_fragment, request)
  local f = copy_fragment(local_fragment)

  if request.tag == 'append' then
    local offset = #self.records + #(view_fragment.appends or {}) + 1
    f.appends[#f.appends + 1] = request.record
    return true, { value = offset }, f
  end

  if request.tag == 'next_offset' then
    return true, { value = #self.records + #(view_fragment.appends or {}) + 1 }, f
  end

  if request.tag == 'read_from' then
    local records = view_records(self, view_fragment)
    local offset = request.offset or 1
    if offset < 1 then offset = 1 end
    local out = {}
    for i = offset, #records do out[#out + 1] = records[i] end
    return true, { value = out }, f
  end

  return false, 'unknown log request'
end

function Log:step_fragment(fragment, request)
  return self:step_fragment_with_view(fragment, fragment, request)
end

function Log:merge_fragments(a, b)
  if a.base_version ~= b.base_version then return false, 'log version conflict' end
  local out = copy_fragment(a)
  for i = 1, #(b.appends or {}) do out.appends[#out.appends + 1] = b.appends[i] end
  return true, out
end

function Log:validate_fragment(fragment)
  return self.version == fragment.base_version
end

function Log:prepare_commit_fragment(fragment, commit)
  for i = 1, #(fragment.appends or {}) do
    commit:emit({ tag = 'log.append', log = self, record = fragment.appends[i] })
  end
end

function Log:commit_fragment(fragment)
  if #(fragment.appends or {}) > 0 then
    for i = 1, #fragment.appends do self.records[#self.records + 1] = fragment.appends[i] end
    self.version = self.version + 1
  end
end

return Log
