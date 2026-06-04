-- Public resource-facing effect descriptor constructors.

local Kernel = require('et.kernel')
local Util = Kernel.Util

local Effect = {}
function Effect.wake(key, payload)
  local out = { tag = 'wake', key = key }
  if type(payload) == 'table' then
    for k, v in pairs(payload) do out[k] = Util.copy_descriptor(v) end
  elseif payload ~= nil then
    out.payload = Util.copy_descriptor(payload)
  end
  return out
end

function Effect.kick(key, payload)
  local out = { tag = 'kick', key = key }
  if type(payload) == 'table' then
    for k, v in pairs(payload) do out[k] = Util.copy_descriptor(v) end
  elseif payload ~= nil then
    out.payload = Util.copy_descriptor(payload)
  end
  return out
end

function Effect.publish(topic, payload)
  return { tag = 'publish', topic = topic, payload = Util.copy_descriptor(payload) }
end

function Effect.resource(kind, key, payload)
  return { tag = kind, key = key, payload = Util.copy_descriptor(payload) }
end

return Effect
