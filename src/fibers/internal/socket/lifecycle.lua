-- Shared helpers for explicit socket lifecycle resources.

local Op = require('fibers.op')

local Lifecycle = {}

function Lifecycle.copy(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

function Lifecycle.wait_for(machine, select)
  local function loop()
    return machine:snapshot_op():and_then(function(snapshot)
      local option, wait = select(snapshot.value)
      if option then
        return option
      end
      if wait then
        return machine:changed_op(snapshot.version):and_then(loop)
      end
      return Op.never()
    end)
  end
  return loop()
end

return Lifecycle
