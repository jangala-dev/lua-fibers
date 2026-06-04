-- ET kernel: shared classified outcomes, phase tokens, origins,
-- dependencies, safe values, and the consequence-log algebra used by evidence rows.
--
-- Keep this file as bottom vocabulary only. Attempts, proof nets, selected worlds,
-- certificates, resources, and scheduling live in higher layers.

local Status, Util, Phase, Origin, Dependency

-- from machine/status.lua
do
  Status = {}

  local VALID = {
    found = true,
    absent = true,
    stale = true,
    conflict = true,
    budget = true,
    fatal = true,
    reject_candidate = true,
    pending = true,
  }

  local function copy_list(xs)
    local out = {}
    for i = 1, #(xs or {}) do out[i] = xs[i] end
    return out
  end

  local function make(tag, fields)
    if not VALID[tag] then error('Status: invalid tag ' .. tostring(tag), 3) end
    local out = { tag = tag }
    fields = fields or {}
    for k, v in pairs(fields) do out[k] = v end
    return out
  end

  function Status.found(value)
    return make('found', { value = value })
  end

  function Status.absent(reason, detail)
    return make('absent', { reason = reason, detail = detail })
  end

  function Status.stale(resources, reason, detail)
    return make('stale', {
      resources = copy_list(resources),
      reason = reason,
      detail = detail,
    })
  end

  function Status.conflict(reason, detail)
    return make('conflict', { reason = reason, detail = detail })
  end

  function Status.budget(reason, detail)
    return make('budget', { reason = reason, detail = detail })
  end

  function Status.fatal(reason, detail)
    return make('fatal', { reason = reason, detail = detail })
  end

  function Status.pending(reason, detail)
    return make('pending', { reason = reason, detail = detail })
  end

  function Status.reject_candidate(reason, detail)
    return make('reject_candidate', { reason = reason, detail = detail })
  end

  function Status.is(x, tag)
    return type(x) == 'table' and x.tag == tag
  end

  function Status.is_found(x)
    return Status.is(x, 'found')
  end

  function Status.is_reject_candidate(x)
    return Status.is(x, 'reject_candidate')
  end

  function Status.expect_found(x, where)
    if not Status.is_found(x) then
      error((where or 'status') .. ': expected found, got ' .. tostring(x and x.tag), 2)
    end
    return x.value
  end
end

-- from machine/util.lua
do
  local unpack_ = table.unpack or unpack

  Util = {}

  function Util.pack(...)
    return { n = select('#', ...), ... }
  end

  function Util.unpack(row, i, j)
    row = row or { n = 0 }
    return unpack_(row, i or 1, j or row.n or #row)
  end

  function Util.copy_row(row)
    row = row or { n = 0 }
    local out = { n = row.n or #row }
    for i = 1, out.n do out[i] = row[i] end
    return out
  end

  function Util.copy_list(xs)
    local out = {}
    for i = 1, #(xs or {}) do out[i] = xs[i] end
    return out
  end

  function Util.append_list(dst, src)
    dst = dst or {}
    for i = 1, #(src or {}) do dst[#dst + 1] = src[i] end
    return dst
  end


  function Util.is_et_identity_ref(x)
    return type(x) == 'table' and (
      x.__et_resource == true or
      x.__et_owner == true or
      x.__et_waitset == true or
      x.__et_scope == true or
      x.__et_origin == true or
      x.__et_obligation == true
    )
  end

  function Util.copy_descriptor(x, seen)
    local op = type(x)
    if op == 'nil' or op == 'boolean' or op == 'number' or op == 'string' then return x end
    if op ~= 'table' then
      error('descriptor contains unsupported value of type ' .. op, 3)
    end
    if Util.is_et_identity_ref(x) then return x end
    if getmetatable(x) ~= nil then
      error('descriptor contains unmarked identity table; mark ET resources or use plain data', 3)
    end
    seen = seen or {}
    if seen[x] then return seen[x] end
    local out = {}
    seen[x] = out
    for k, v in pairs(x) do
      out[Util.copy_descriptor(k, seen)] = Util.copy_descriptor(v, seen)
    end
    return out
  end
end

-- from machine/phase.lua
do
  Phase = {}

  local stack = {}

  local Token = {}
  Token.__index = Token

  function Token:assert(expected)
    if not self.active then
      error('phase token: expired token for ' .. tostring(expected), 2)
    end
    if self.phase ~= expected then
      error('phase token: expected ' .. tostring(expected) .. ', got ' .. tostring(self.phase), 2)
    end
    return self
  end

  function Phase.current()
    local top = stack[#stack]
    return top and top.phase or 'idle'
  end

  function Phase.with(phase, fn, ...)
    if type(fn) ~= 'function' then error('Phase.with: expected function', 2) end
    local token = setmetatable({ phase = phase, active = true }, Token)
    stack[#stack + 1] = token
    local results = Util.pack(pcall(fn, token, ...))
    stack[#stack] = nil
    token.active = false
    if not results[1] then error(results[2], 0) end
    return Util.unpack(results, 2, results.n)
  end

  function Phase.require(token, phase)
    if type(token) ~= 'table' or getmetatable(token) ~= Token then
      error('phase token: missing token for ' .. tostring(phase), 2)
    end
    return token:assert(phase)
  end

  function Phase.require_any(token, phases)
    if type(token) ~= 'table' or getmetatable(token) ~= Token then
      error('phase token: missing token', 2)
    end
    if not token.active then
      error('phase token: expired token', 2)
    end
    for i = 1, #(phases or {}) do
      if token.phase == phases[i] then return token end
    end
    error('phase token: expected one of permitted phases, got ' .. tostring(token.phase), 2)
  end
end

Status.Util = Util
Status.Phase = Phase

return {
  Status = Status,
  Result = Status,
  Util = Util,
  Phase = Phase,
}
