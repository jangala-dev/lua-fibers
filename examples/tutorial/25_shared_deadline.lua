package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Keep one absolute deadline across several stages. Replacing it with a fresh
-- relative timeout at each stage would accidentally extend the total budget.

local fibers = require('fibers')
local Op = require('fibers.op')
local Sleep = require('fibers.sleep')
local Host = require('fibers.host')

local first_stage, second_stage, finished_at

fibers.run(function()
  local deadline = fibers.now() + 3

  first_stage = fibers.perform(Op.named_choice({
    reply = Sleep.sleep_op(1):map(function()
      return 'headers received'
    end),
    timeout = Sleep.sleep_until_op(deadline):map(function()
      return 'deadline reached'
    end),
  }))

  second_stage = fibers.perform(Op.named_choice({
    reply = Sleep.sleep_op(3):map(function()
      return 'body received'
    end),
    timeout = Sleep.sleep_until_op(deadline):map(function()
      return 'deadline reached'
    end),
  }))

  finished_at = fibers.now()
end, { host = Host.manual() })

assert(first_stage == 'reply')
assert(second_stage == 'timeout')
assert(finished_at == 3)
print('stages:', first_stage, second_stage, 'finished at:', finished_at)
