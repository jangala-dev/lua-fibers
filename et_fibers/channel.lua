local core = require('etfcore')
local Op = core.Op

-- --------------------------------------------------------------------------
-- Channel resource: put/get ports cut against each other.
-- --------------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

function Channel.new(name)
  return setmetatable({ name = name or 'channel' }, Channel)
end

function Channel:put(value)
  return Op.request(self, { tag = 'put', value = value })
end

function Channel:get()
  return Op.request(self, { tag = 'get' })
end

function Channel:empty_fragment()
  return { matches = {} }
end

function Channel:merge_fragments(a, b)
  local out = { matches = {} }
  for k, v in pairs(a.matches or {}) do out.matches[k] = v end
  for k, v in pairs(b.matches or {}) do
    local old = out.matches[k]
    if old and old ~= v then return false, 'channel match conflict' end
    out.matches[k] = v
  end
  return true, out
end

function Channel:validate_fragment(_) return true end
function Channel:prepare_commit_fragment(_, _) end
function Channel:commit_fragment(_) end

function Channel:try_match(a, b)
  if a.tag == 'put' and b.tag == 'get' then
    local token = {}
    local fragment = { matches = { [token] = a.value } }
    return true,
      { value = true, fragments = { [self] = fragment } },
      { value = a.value, fragments = { [self] = fragment } }

  elseif a.tag == 'get' and b.tag == 'put' then
    local token = {}
    local fragment = { matches = { [token] = b.value } }
    return true,
      { value = b.value, fragments = { [self] = fragment } },
      { value = true, fragments = { [self] = fragment } }
  end

  return false
end

return Channel
