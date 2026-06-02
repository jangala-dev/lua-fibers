local core = require('etfcore')
local Op = core.Op

-- --------------------------------------------------------------------------
-- Cell resource: scalar transactional state.
-- --------------------------------------------------------------------------

local Cell = {}
Cell.__index = Cell

local function copy_fragment(f)
  return {
    base_version = f.base_version,
    value = f.value,
    written = f.written and true or false,
  }
end

function Cell.new(value, name)
  return setmetatable({ value = value, version = 0, name = name or 'cell' }, Cell)
end

function Cell:get_op()
  return Op.access(self, { tag = 'get' })
end

function Cell:set_op(value)
  return Op.access(self, { tag = 'set', value = value })
end

function Cell:update_op(f)
  if type(f) ~= 'function' then error('Cell:update_op expects a function', 2) end
  return self:get_op():and_then(function(v)
    return self:set_op(f(v))
  end)
end

function Cell:empty_fragment()
  return { base_version = self.version, value = self.value, written = false }
end

function Cell:step_fragment_with_view(view_fragment, local_fragment, request)
  if request.tag == 'get' then
    return true, { value = view_fragment.value }, copy_fragment(local_fragment)
  end

  if request.tag == 'set' then
    local f = copy_fragment(local_fragment)
    f.value = request.value
    f.written = true
    return true, { value = true }, f
  end

  return false, 'unknown cell request'
end

function Cell:step_fragment(fragment, request)
  return self:step_fragment_with_view(fragment, fragment, request)
end

function Cell:merge_fragments(a, b)
  if a.base_version ~= b.base_version then
    return false, 'cell version conflict'
  end

  if a.written and b.written and a.value ~= b.value then
    return false, 'conflicting cell writes'
  end

  if b.written then return true, copy_fragment(b) end
  return true, copy_fragment(a)
end

function Cell:validate_fragment(fragment)
  return self.version == fragment.base_version
end

function Cell:prepare_commit_fragment(fragment, commit)
  if fragment.written then
    commit:emit({ tag = 'cell.set', cell = self, value = fragment.value })
  end
end

function Cell:commit_fragment(fragment)
  if fragment.written then
    self.value = fragment.value
    self.version = self.version + 1
  end
end

return Cell
