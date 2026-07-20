local fibers = require('fibers')
local socket = require('fibers.socket')

local Contract = {}

local function assert_truthy(value, message)
  if not value then error(message or 'expected truthy value', 3) end
  return value
end

function Contract.exercise(name, host)
  local report = fibers.try_run(function()
    local query = socket.resolve_name('localhost', 80, { family = 'inet4' })
    local addresses, err = query:result()
    assert_truthy(addresses, name .. ' resolver failed: ' .. tostring(err))
    assert(#addresses > 0, name .. ' resolver returned no addresses')
    for i = 1, #addresses do
      assert(addresses[i].kind == 'inet4', name .. ' resolver ignored IPv4 family filter')
      assert(addresses[i].port == 80, name .. ' resolver lost service port')
    end
    assert(query:close(name .. ' resolver contract'))
  end, { host = host })
  assert_truthy(report.ok, name .. ' resolver contract failed: ' .. report:tostring())
  report.runtime:assert_io_quiescent(name .. ' resolver contract')
  return true
end

return Contract
