package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- The callback phases are part of the programming model:
--   1. map/and_then/guards construct possible worlds and must remain pure;
--   2. effect prepare is pure, then discharge runs after commitment;
--   3. wrap runs in the resumed participant and may perform ordinary work.

local fibers = require('fibers')
local Op = require('fibers.op')
local Effect = require('fibers.effect')

local events = {}
local LogKind

LogKind = Effect.kind({
  name = 'tutorial.log',
  key = function(payload)
    return payload.id
  end,
  merge = function(a, _b)
    return a
  end,
  prepare = function(_runtime, payload)
    -- Pure: construct a plan only. Do not append to events here.
    return {
      kind = LogKind,
      payload = payload,
      discharge = function(_runtime, prepared)
        events[#events + 1] = 'effect: ' .. prepared.payload.message
      end,
    }
  end,
})

local result
fibers.run(function()
  local effect = Effect.of(LogKind, { id = 'selected', message = 'committed' })

  result = fibers.perform(Op.emit(effect)
    :map(function()
      return 'selected' -- speculative and pure
    end)
    :wrap(function(value)
      events[#events + 1] = 'wrap: ' .. value
      return value
    end))
end)

assert(result == 'selected')
assert(table.concat(events, ',') == 'effect: committed,wrap: selected')
print(table.concat(events, ' then '))
