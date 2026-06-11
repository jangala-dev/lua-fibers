-- Internal Source state mutation.
--
-- Public Source values are consumers only.  External facts enter through
-- Runtime-bound producer capabilities, which call these helpers and invalidate
-- the runtime cursor in the same step.

local Op = require('fibers.base.op')
local OpPack = Op._pack

local SourceState = {}

function SourceState.arrive(source, ...)
  if source.kind == 'signal' then
    source.ready = true
    source.vals = OpPack(...)
    source.version = (source.version or 0) + 1
    return source
  elseif source.kind == 'queue' then
    source.queue = source.queue or {}
    source.head = source.head or 1
    source.tail = (source.tail or 0) + 1
    source.queue[source.tail] = OpPack(...)
    source.version = (source.version or 0) + 1
    return source
  elseif source.kind == 'readiness' then
    local a, b = ...
    if b == nil and type(a) ~= 'string' then
      source.ready[source.mode or 'read'] = not not a
    else
      source.ready[a or source.mode or 'read'] = (b == nil) and true or not not b
    end
    source.version = (source.version or 0) + 1
    return source
  end
  error('arrival is not supported by ' .. tostring(source.kind) .. ' source', 2)
end

function SourceState.clear(source, mode)
  if source.kind == 'signal' then
    source.ready = false
    source.vals = nil
    source.version = (source.version or 0) + 1
    return source
  elseif source.kind == 'queue' then
    source.queue = {}
    source.head = 1
    source.tail = 0
    source.version = (source.version or 0) + 1
    return source
  elseif source.kind == 'readiness' then
    if mode == nil then source.ready = {} else source.ready[mode or source.mode or 'read'] = nil end
    source.version = (source.version or 0) + 1
    return source
  end
  error('clear is not supported by ' .. tostring(source.kind) .. ' source', 2)
end

return SourceState
