local core = require('etfcore')
local Op = core.Op

-- --------------------------------------------------------------------------
-- Queue resource: ordered transactional state.
--
-- The fragment stores a complete tentative queue once touched.  This keeps the
-- primitive small and deterministic: independent conflicting queue edits do not
-- silently choose an order.
-- --------------------------------------------------------------------------

local Queue = {}
Queue.__index = Queue

local function copy_list(xs)
  local ys = {}
  if xs then for i = 1, #xs do ys[i] = xs[i] end end
  return ys
end

local function copy_fragment(f)
  return {
    base_version = f.base_version,
    items = copy_list(f.items),
    touched = f.touched and true or false,
  }
end

local function lists_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

function Queue.new(items, name)
  return setmetatable({ items = copy_list(items or {}), version = 0, name = name or 'queue' }, Queue)
end

function Queue:put_op(value)
  return Op.access(self, { tag = 'put', value = value })
end

function Queue:get_op()
  return Op.access(self, { tag = 'get' })
end

function Queue:peek_op()
  return Op.access(self, { tag = 'peek' })
end

function Queue:empty_fragment()
  return { base_version = self.version, items = copy_list(self.items), touched = false }
end

function Queue:step_fragment_with_view(view_fragment, local_fragment, request)
  local f = copy_fragment(local_fragment)

  if request.tag == 'peek' then
    if #view_fragment.items == 0 then return false, 'queue empty' end
    return true, { value = view_fragment.items[1] }, f
  end

  if not f.touched then
    f.items = copy_list(view_fragment.items)
    f.touched = true
  end

  if request.tag == 'put' then
    f.items[#f.items + 1] = request.value
    return true, { value = true }, f
  end

  if request.tag == 'get' then
    if #f.items == 0 then return false, 'queue empty' end
    local value = table.remove(f.items, 1)
    return true, { value = value }, f
  end

  return false, 'unknown queue request'
end

function Queue:step_fragment(fragment, request)
  return self:step_fragment_with_view(fragment, fragment, request)
end

function Queue:merge_fragments(a, b)
  if a.base_version ~= b.base_version then return false, 'queue version conflict' end
  if not a.touched then return true, copy_fragment(b) end
  if not b.touched then return true, copy_fragment(a) end
  if lists_equal(a.items, b.items) then return true, copy_fragment(a) end
  return false, 'conflicting queue edits'
end

function Queue:validate_fragment(fragment)
  return self.version == fragment.base_version
end

function Queue:prepare_commit_fragment(fragment, commit)
  if fragment.touched then
    commit:emit({ tag = 'queue.set', queue = self })
  end
end

function Queue:commit_fragment(fragment)
  if fragment.touched then
    self.items = copy_list(fragment.items)
    self.version = self.version + 1
  end
end

return Queue
