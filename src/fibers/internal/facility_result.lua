-- Static trusted result codecs used by compiled facility descriptors.

local Algebra = require('fibers.internal.kernel.algebra')
local Op = require('fibers.op')

local M = {}
local function pack(session, ...)
  return session and session:pack(...) or Op._pack(...)
end

function M.encode(codec, program, value, session)
  codec = codec or { kind = 'value' }
  local kind = codec.kind
  if kind == 'constant' then
    return pack(session, codec.value)
  end
  if kind == 'value' then
    return pack(session, value)
  end
  if kind == 'present' then
    return pack(session, value ~= Algebra.ABSENT)
  end
  if kind == 'presence' then
    if value == Algebra.ABSENT or (codec.nil_sentinel and value == codec.nil_sentinel) then
      return pack(session, nil)
    end
    return pack(session, value)
  end
  if kind == 'index_entry' then
    return pack(session, value and {
      key = value.key,
      rank = value.rank,
      value = value.value,
      seq = value.seq,
    })
  end
  if kind == 'scalar_snapshot' then
    return pack(session, { value = value, version = program.location.version })
  end
  if kind == 'counter_state' then
    local owner = program.resource
    return pack(session, {
      value = value,
      min = owner.min,
      max = owner.max,
      version = program.location.version,
    })
  end
  error('unknown facility result codec ' .. tostring(kind), 2)
end

return M
