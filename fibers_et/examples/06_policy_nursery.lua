package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local message
local child

local st = fibers.launch(fibers.facility.policy.nursery(), function(nursery)
  local ch = fibers.Channel.new('nursery-example')

  child = fibers.spawn(function()
    fibers.perform(ch:put_op('hello from a structured task'))
  end, 'sender')

  message = fibers.perform(ch:get_op())

  -- The nursery policy admits tasks to its Region.  On exit it seals the
  -- Region, waits for owned tasks, and retires those that have completed.
  assert(nursery.region)
end)

assert(st.tag == 'found')
assert(message == 'hello from a structured task')
assert(child.owner == nil)

print('06_policy_nursery.lua: ok')
