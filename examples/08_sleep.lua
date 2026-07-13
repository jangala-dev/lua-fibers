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

-- Sleep facility: beginner-facing standalone use with Lua's os.time.
--
-- fibers.sleep_op(d) is an option.  It does not block the process by itself.
-- The pure Lua host below uses os.time as the runtime clock and os.execute
--("sleep N") as its deliberately small blocking mechanism.  The standalone
-- runner ties the two together.

local fibers = require('fibers')
local PureHost = require('fibers.host.pure')

local DELAY = 4

local function stamp(t)
  return os.date('%H:%M:%S', t or os.time())
end

local host = PureHost.new({
  now = os.time,
  on_wait = function(deadline, delay)
    print(
      stamp(),
      'host: no runnable work; sleeping about ' .. tostring(math.ceil(delay)) .. ' second(s)'
    )
    print(stamp(), 'host: next runtime deadline is ' .. stamp(deadline))
  end,
  on_wake = function(deadline)
    print(stamp(), 'host: woke after waiting for ' .. stamp(deadline) .. '; re-entering runtime')
  end,
})

print(stamp(), 'driver: starting standalone run')

local done = false
local st = fibers.try_run(function()
  print(stamp(), 'fibre: starting')
  print(stamp(), 'fibre: performing sleep_op(' .. DELAY .. ')')

  fibers.perform(fibers.sleep_op(DELAY))

  print(stamp(), 'fibre: resumed after sleep')
  done = true
end, { host = host, name = 'sleep-example' }).runtime_status

print(stamp(), 'driver: runtime finished with status ' .. tostring(st and st.tag))
assert(done, 'sleeping fibre should have resumed')
