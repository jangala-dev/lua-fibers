local core = require('etfcore')
local Op = core.Op

-- --------------------------------------------------------------------------
-- Signal resource: transactional wake/wait pulse.
--
-- wake_op participates in a same-commit rendezvous with wait_op and also
-- records a committed generation bump.  wait_op(cursor) can also close
-- immediately if a prior committed wake has advanced the generation.
-- --------------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

local function copy_fragment(f)
  return { base_generation = f.base_generation, wakes = f.wakes or 0 }
end

function Signal.new(name)
  return setmetatable({ generation = 0, name = name or 'signal' }, Signal)
end

function Signal:cursor()
  return self.generation
end

function Signal:wait_op(cursor)
  cursor = cursor or self:cursor()
  return Op.guard(function()
    if self.generation > cursor then return Op.always(true) end
    return Op.request(self, { tag = 'wait', cursor = cursor })
  end)
end

function Signal:wake_op()
  return Op.access(self, { tag = 'wake' }):and_then(function()
    return Op.request(self, { tag = 'wake' }):or_else(Op.always(true))
  end):map(function()
    return true
  end)
end

function Signal:empty_fragment()
  return { base_generation = self.generation, wakes = 0 }
end

function Signal:step_fragment(fragment, request)
  local f = copy_fragment(fragment)
  if request.tag == 'wake' then
    f.wakes = f.wakes + 1
    return true, { value = true }, f
  end
  return false, 'unknown signal access request'
end

function Signal:merge_fragments(a, b)
  if a.base_generation ~= b.base_generation then return false, 'signal generation conflict' end
  return true, { base_generation = a.base_generation, wakes = (a.wakes or 0) + (b.wakes or 0) }
end

function Signal:validate_fragment(_fragment)
  -- A wake pulse remains valid even if another wake commits first.
  return true
end

function Signal:prepare_commit_fragment(fragment, commit)
  for _ = 1, fragment.wakes or 0 do
    commit:emit({ tag = 'signal.wake', signal = self })
  end
end

function Signal:commit_fragment(fragment)
  if (fragment.wakes or 0) > 0 then
    self.generation = self.generation + fragment.wakes
  end
end

function Signal:try_match(a, b)
  if a.tag == 'wake' and b.tag == 'wait' then
    return true, { value = true }, { value = true }
  elseif a.tag == 'wait' and b.tag == 'wake' then
    return true, { value = true }, { value = true }
  end
  return false
end

return Signal
