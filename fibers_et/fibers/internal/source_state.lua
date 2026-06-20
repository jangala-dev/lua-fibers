-- Internal Source state mutation.
--
-- Public Source values are consumers only.  External facts enter through
-- Runtime-bound producer capabilities, which call these helpers and invalidate
-- the runtime cursor in the same step.

local Op = require('fibers.base.op')
local Resources = require('fibers.kernel.resources')
local OpPack = Op._pack

local SourceState = {}

local function readiness_mode(source, mode)
  mode = mode or source.mode or 'read'
  if mode == 'wr' then mode = 'write' end
  if mode ~= 'read' and mode ~= 'write' then error('readiness mode must be read or write', 3) end
  return mode
end

function SourceState.arrive(source, ...)
  if source.kind == 'signal' then
    source.ready = true
    source.vals = OpPack(...)
    source.version = (source.version or 0) + 1
    Resources.invalidate_source(source, 'signal.state', nil, 'signal arrived')
    return source
  elseif source.kind == 'queue' then
    source.queue = source.queue or {}
    source.head = source.head or 1
    local was_empty = ((source.tail or 0) - (source.head or 1) + 1) <= 0
    source.tail = (source.tail or 0) + 1
    source.queue[source.tail] = OpPack(...)
    source.version = (source.version or 0) + 1
    if was_empty then
      Resources.invalidate_source(source, 'queue.empty', nil, 'queue became non-empty')
      Resources.invalidate_source(source, 'queue.head', nil, 'queue head appeared')
    end
    Resources.invalidate_source(source, 'queue.tail', nil, 'queue tail changed')
    return source
  elseif source.kind == 'readiness' then
    source.ready = source.ready or {}
    local n = select('#', ...)
    local first = ...
    local mode, value
    if type(first) == 'string' then
      mode = readiness_mode(source, first)
      value = select(2, ...)
      if n <= 1 then value = true end
    else
      mode = readiness_mode(source, nil)
      value = first
      if n == 0 then value = true end
    end
    if value == false or value == nil then source.ready[mode] = nil else source.ready[mode] = true end
    source.version = (source.version or 0) + 1
    Resources.invalidate_source(source, 'readiness', mode, 'readiness changed')
    return source
  end
  error('arrival is not supported by ' .. tostring(source.kind) .. ' source', 2)
end

function SourceState.clear(source, mode)
  if source.kind == 'signal' then
    source.ready = false
    source.vals = nil
    source.version = (source.version or 0) + 1
    Resources.invalidate_source(source, 'signal.state', nil, 'signal cleared')
    return source
  elseif source.kind == 'queue' then
    source.queue = {}
    source.head = 1
    source.tail = 0
    source.version = (source.version or 0) + 1
    Resources.invalidate_source(source, 'queue.empty', nil, 'queue cleared')
    Resources.invalidate_source(source, 'queue.head', nil, 'queue cleared')
    Resources.invalidate_source(source, 'queue.tail', nil, 'queue cleared')
    return source
  elseif source.kind == 'readiness' then
    if mode == nil then
      source.ready = {}
      Resources.invalidate_source(source, 'readiness', 'read', 'readiness cleared')
      Resources.invalidate_source(source, 'readiness', 'write', 'readiness cleared')
    else
      local m = readiness_mode(source, mode)
      source.ready[m] = nil
      Resources.invalidate_source(source, 'readiness', m, 'readiness cleared')
    end
    source.version = (source.version or 0) + 1
    return source
  end
  error('clear is not supported by ' .. tostring(source.kind) .. ' source', 2)
end

return SourceState
