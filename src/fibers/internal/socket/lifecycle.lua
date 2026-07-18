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
  -- Selectors may return a terminal value or a transition on the lifecycle
  -- machine itself.  Declare that complete closed domain rather than treating
  -- every lifecycle wait as an opaque continuation capable of touching any
  -- resource in the runtime.
  local footprint = {
    external = true,
    locations = {
      [machine._location] = {
        read = true,
        write = true,
        wait = true,
        supplies = { any = true },
      },
    },
  }
  local function loop()
    return machine:snapshot_op():and_then(function(snapshot)
      local option, wait = select(snapshot.value)
      if option then
        return option
      end
      if wait then
        return machine:changed_op(snapshot.version):and_then(loop, footprint)
      end
      return Op.never()
    end, footprint)
  end
  return loop()
end

return Lifecycle
