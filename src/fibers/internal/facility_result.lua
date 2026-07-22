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
  if kind == 'project' then
    return pack(session, codec.project(value, program))
  end
  error('unknown facility result codec ' .. tostring(kind), 2)
end

return M
