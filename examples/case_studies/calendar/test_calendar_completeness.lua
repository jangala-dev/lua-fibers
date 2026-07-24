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
local fibers = require('fibers')
local FibersOp = require('fibers.op')
local FibersCalendar = require('examples.case_studies.calendar.calendar')
local Calendar, Op = FibersCalendar, FibersOp

local seed = 2463534242
local function rand(n)
  seed = (1103515245 * seed + 12345) % 2147483648
  return seed % n
end
local function overlap(a0, a1, b0, b1)
  return a0 < b1 and b0 < a1
end

for case = 1, 80 do
  local initial = {}
  for i = 1, 6 do
    local start = rand(18)
    local len = 1 + rand(5)
    initial[#initial + 1] =
      { id = i, start = start, finish = start + len, resources = { rand(2) == 0 and 'a' or 'b' } }
  end
  local resources = rand(2) == 0 and { 'a' } or { 'a', 'b' }
  local duration = 1 + rand(5)
  local latest = 24
  local expected
  for start = 0, latest - duration do
    local busy = false
    for _, r in ipairs(initial) do
      local shares = false
      for _, wanted in ipairs(resources) do
        if r.resources[1] == wanted then
          shares = true
        end
      end
      if shares and overlap(start, start + duration, r.start, r.finish) then
        busy = true
        break
      end
    end
    if not busy then
      expected = start
      break
    end
  end

  local cal = Calendar.new(initial)
  local got
  fibers.run(function()
    local r = fibers.perform(
      cal
        :find_op({ resources = resources, earliest = 0, latest = latest, duration = duration })
        :or_else(Op.always(nil))
    )
    got = r and r.start or nil
  end, { quiet_deadlock = true })
  assert(got == expected, ('case %d: expected %s, got %s'):format(case, tostring(expected), tostring(got)))
end

print('examples/case_studies/calendar/test_calendar_completeness.lua: ok')
