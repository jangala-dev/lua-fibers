package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
local fibers = require('fibers')
local Petri, Calendar = fibers.Petri, fibers.Calendar

local function measure(fn)
  collectgarbage('collect')
  local t = os.clock()
  fn()
  return os.clock() - t
end

local function petri_cycle(n)
  local net = Petri.new({ a = { true } })
  local ab = net:transition({ inputs = { { place = 'a', as = 'x' } }, produce = function(b) return { b = { b.x } } end, result = function() return true end })
  local ba = net:transition({ inputs = { { place = 'b', as = 'x' } }, produce = function(b) return { a = { b.x } } end, result = function() return true end })
  fibers.run(function()
    for _ = 1, n do fibers.perform(net:fire_op(ab)); fibers.perform(net:fire_op(ba)) end
  end, { quiet_deadlock = true })
end

local function petri_grow(n)
  local net = Petri.new()
  fibers.run(function()
    for i = 1, n do fibers.perform(net:put_op('p', i)) end
  end, { quiet_deadlock = true })
end

local function calendar_cycle(n)
  local cal = Calendar.new()
  fibers.run(function()
    for _ = 1, n do
      local r = fibers.perform(cal:reserve_at_op({ 'room' }, 0, 1))
      fibers.perform(cal:cancel_op(r.id))
    end
  end, { quiet_deadlock = true })
end

local function calendar_grow(n)
  local cal = Calendar.new()
  fibers.run(function()
    for i = 1, n do fibers.perform(cal:reserve_at_op({ 'room' }, i, i + 1)) end
  end, { quiet_deadlock = true })
end

for _, n in ipairs({100, 250, 500, 1000}) do
  print(string.format('petri_cycle %d %.6f', n, measure(function() petri_cycle(n) end)))
end
for _, n in ipairs({50, 100, 200, 400}) do
  print(string.format('petri_grow %d %.6f', n, measure(function() petri_grow(n) end)))
end
for _, n in ipairs({100, 250, 500, 1000}) do
  print(string.format('calendar_cycle %d %.6f', n, measure(function() calendar_cycle(n) end)))
end
for _, n in ipairs({50, 100, 200, 400}) do
  print(string.format('calendar_grow %d %.6f', n, measure(function() calendar_grow(n) end)))
end
