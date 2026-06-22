-- Internal Source state mutation through managed validity capabilities.

local Op = require('fibers.base.op')
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
    source._validity:set(OpPack(...), 'signal arrived')
  elseif source.kind == 'queue' then
    source._validity:push(OpPack(...), 'queue arrival')
  elseif source.kind == 'readiness' then
    local n, first = select('#', ...), ...
    local mode, value
    if type(first) == 'string' then
      mode, value = readiness_mode(source, first), select(2, ...)
      if n <= 1 then value = true end
    else
      mode, value = readiness_mode(source), first
      if n == 0 then value = true end
    end
    source._validity:set(mode, value ~= false and value ~= nil, 'readiness changed')
  else
    error('arrival is not supported by ' .. tostring(source.kind) .. ' source', 2)
  end
  return source
end

function SourceState.clear(source, mode)
  if source.kind == 'signal' then
    source._validity:clear('signal cleared')
  elseif source.kind == 'queue' then
    source._validity:clear('queue cleared')
  elseif source.kind == 'readiness' then
    if mode == nil then source._validity:clear(nil, 'readiness cleared')
    else source._validity:clear(readiness_mode(source, mode), 'readiness cleared') end
  else
    error('clear is not supported by ' .. tostring(source.kind) .. ' source', 2)
  end
  return source
end

return SourceState
