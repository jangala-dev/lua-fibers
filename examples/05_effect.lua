package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Effect: committed runtime obligation.
--
-- Effects are the public form of typed transaction effects.  They are
-- discharged iff the selected world commits, after resource commit and before
-- selected fibres resume.

local fibers = require('fibers')

local log = {}
local counter = fibers.Scalar.new(0, 'counter')

local LogKind
LogKind = fibers.Effect.kind({
  name = 'example-log',
  key = function(payload)
    return payload.id
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_rt, payload)
    return {
      kind = LogKind,
      key = payload.id,
      payload = payload,
      discharge = function(_rt, entry)
        log[#log + 1] = entry.payload.message
      end,
    }
  end,
})

local function log_effect(id, message)
  return fibers.Effect.of(LogKind, { id = id, message = message })
end

fibers.run(function()
  fibers.perform(fibers.tensor({
    counter:write_op(1),
    fibers.after_commit(log_effect('counter-updated', 'counter was committed')),
  }))
end)

print('counter:', counter.value)
print('effect log:', log[1])
