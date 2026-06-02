package.path = './?.lua;../?.lua;./?/init.lua;../?/init.lua;' .. package.path

local core = require('etfcore')
local Op = core.Op
local Runtime = core.Runtime
local Channel = require('channel')

-- --------------------------------------------------------------------------
-- Demo 1: Triple swap
-- --------------------------------------------------------------------------

local function pair(a, b)
  return { a, b }
end

local function triple_swap_op(ch, x)
  local reply = Channel.new('reply-' .. tostring(x))

  local client = ch:put({ x = x, reply = reply }):and_then(function()
    return reply:get()
  end)

  local leader = ch:get():and_then(function(m2)
    return ch:get():and_then(function(m3)
      return m2.reply:put(pair(m3.x, x)):and_then(function()
        return m3.reply:put(pair(x, m2.x)):and_then(function()
          return Op.always(pair(m2.x, m3.x))
        end)
      end)
    end)
  end)

  return Op.choice(client, leader)
end

local function demo_triple_swap()
  print('--- demo: triple swap ---')
  local rt = Runtime.new()
  local ch = Channel.new('triple')
  local results = {}

  for i = 1, 3 do
    local x = 10 + i
    rt:spawn(function()
      local got = Op.perform(triple_swap_op(ch, x))
      results[x] = got
      print(string.format('swapper %d got {%d,%d}', x, got[1], got[2]))
    end, 'swapper-' .. tostring(x))
  end

  rt:run()

  local checksum = 0
  for x, got in pairs(results) do checksum = checksum + x + got[1] + got[2] end
  print('triple swap checksum:', checksum)
  print()
end

demo_triple_swap()
