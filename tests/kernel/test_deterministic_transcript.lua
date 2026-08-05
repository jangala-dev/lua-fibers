package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Effect = require('fibers.effect')
local Op = require('fibers.op')
local Rendezvous = require('fibers.resource.rendezvous')
local Runtime = require('fibers.runtime')

local function scenario()
  local transcript = {}
  local function record(value) transcript[#transcript + 1] = value end

  local TraceKind
  TraceKind = Effect.kind({
    name = 'deterministic-transcript',
    key = function(payload) return payload.value end,
    merge = function(left, _right) return left end,
    prepare = function(_runtime, payload)
      return {
        kind = TraceKind,
        payload = payload,
        discharge = function(_runtime, prepared)
          record('effect:' .. prepared.payload.value)
        end,
      }
    end,
  })
  local function effect(value) return Effect.of(TraceKind, { value = value }) end

  local exchange = Rendezvous.new():label('deterministic-transcript')
  local runtime = Runtime.new({ choice_seed = 7 })

  runtime:spawn_raw(function()
    local value = runtime:perform(exchange:get_op())
    record('get:' .. tostring(value))
  end):label('transcript-get')

  runtime:spawn_raw(function()
    runtime:perform(exchange:put_op('payload'))
    record('put')
  end):label('transcript-put')

  runtime:spawn_raw(function()
    local result = runtime:perform(Op.choice(
      Op.always('left'):on_defeat(effect('left-defeated')),
      Op.each({ Op.always('right'), Op.emit(effect('right-committed')) }):map(function(rows)
        return rows[1][1]
      end)
    ))
    record('choice:' .. tostring(result))
  end):label('transcript-choice')

  while true do
    local status = runtime:run()
    if status.tag ~= 'found' then break end
  end
  return table.concat(transcript, '|')
end

local expected = scenario()
for i = 1, 40 do
  local actual = scenario()
  if actual ~= expected then
    error(string.format('deterministic transcript changed on run %d: expected %s, got %s', i, expected, actual), 0)
  end
end

print('tests/kernel/test_deterministic_transcript.lua: ok')
