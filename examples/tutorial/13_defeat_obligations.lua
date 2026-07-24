package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- on_defeat attaches a typed committed obligation to a competing occurrence.
-- It runs only when another incompatible branch commits: retry and fallback are
-- not defeat.

local fibers = require('fibers')
local Op = require('fibers.op')
local Effect = require('fibers.effect')

local retired = {}
local RetireKind

RetireKind = Effect.kind({
  name = 'tutorial.retire-proposal',
  key = function(payload)
    return payload.id
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_runtime, payload)
    return {
      kind = RetireKind,
      payload = payload,
      discharge = function(_runtime, prepared)
        retired[#retired + 1] = prepared.payload.id
      end,
    }
  end,
})

local selected
fibers.run(function()
  local rejected = Effect.of(RetireKind, { id = 'remote-proposal' })
  selected = fibers.perform(
    Op.choice(Op.always('use cached answer'), Op.always('use remote answer'):on_defeat(rejected))
  )
end, { choice_seed = 2 })

assert(selected == 'use cached answer')
assert(retired[1] == 'remote-proposal')
print(selected, 'retired:', retired[1])
