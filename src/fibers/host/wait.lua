-- Shared host behaviour when only timer waits remain.

local Host = require('fibers.host')

local Wait = {}

function Wait.block_without_io(host, rt, waits, status, deadline)
  if deadline ~= nil then
    local delay = Host.delay_until(rt, deadline) or 0
    if delay > 0 then
      if host.on_wait then
        host.on_wait(deadline, delay, waits, status)
      end
      local ok, err = host:sleep(delay)
      if not ok then
        error(err, 3)
      end
      if host.on_wake then
        host.on_wake(deadline, waits, status)
      end
    end
    return true, 'time'
  end
  if host.on_unsupported then
    host.on_unsupported(waits, status)
  end
  return nil, 'unsupported-waits'
end

return Wait
