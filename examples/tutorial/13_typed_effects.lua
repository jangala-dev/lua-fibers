package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- Typed effects keep irreversible host work out of speculative search.  This
-- transaction changes the desired radio configuration and emits two partial
-- driver obligations.  Because they have the same kind and key, they merge into
-- one complete driver call if, and only if, the world commits.

local fibers = require('fibers')
local Op = require('fibers.op')
local Effect = require('fibers.effect')
local Cell = require('fibers.resource.cell')

local desired = Cell.new({ channel = 1, power = 1 }):label('desired-radio-config')
local driver_calls = {}
local driver_capabilities = { highest_channel = 11 }

local function copy_fields(value)
  local out = {}
  for key, field in pairs(value) do
    out[key] = field
  end
  return out
end

local function merge_fields(first, second)
  local merged = copy_fields(first)
  for key, value in pairs(second) do
    local present = merged[key]
    if present ~= nil and present ~= value then
      return nil, {
        kind = 'effect_conflict',
        message = 'conflicting radio setting: ' .. tostring(key),
      }
    end
    merged[key] = value
  end
  return merged
end

local ApplyRadioConfig
ApplyRadioConfig = Effect.kind({
  name = 'tutorial.apply-radio-config',

  key = function(payload)
    return payload.radio
  end,

  merge = function(first, second)
    local config, err = merge_fields(first.config, second.config)
    if not config then
      return Effect.reject(err)
    end
    return { radio = first.radio, config = config }
  end,

  prepare = function(_runtime, payload)
    -- Pure and replayable: reject unsupported candidate worlds, but do not
    -- reserve the driver or touch the radio here.
    if payload.config.channel > driver_capabilities.highest_channel then
      return Effect.reject({
        kind = 'unsupported_radio_channel',
        channel = payload.config.channel,
      })
    end

    return {
      kind = ApplyRadioConfig,
      payload = payload,
      discharge = function(_runtime, prepared)
        -- Irreversible host work belongs here, after managed state commits.
        driver_calls[#driver_calls + 1] = prepared.payload
      end,
    }
  end,
})

local function apply_setting(radio, key, value)
  return Op.emit(Effect.of(ApplyRadioConfig, {
    radio = radio,
    config = { [key] = value },
  }))
end

local function configure_radio_op(channel, power)
  return desired:read_op():and_then(Op.guard(function(current)
    local next_config = {
      channel = channel or current.channel,
      power = power or current.power,
    }
    return Op.each({
      desired:write_op(next_config),
      apply_setting('uplink', 'channel', channel),
      apply_setting('uplink', 'power', power),
    }):map(function()
      return next_config
    end)
  end))
end

local fallback
local committed
fibers.run(function()
  -- The complete left branch is defeated.  Neither its Cell write nor either
  -- driver obligation survives into the fallback world.
  fallback = fibers.perform(
    configure_radio_op(6, 4)
      :and_then(Op.never())
      :or_else(Op.always('kept existing configuration'))
  )

  assert(desired.value.channel == 1 and desired.value.power == 1)
  assert(#driver_calls == 0)

  -- Channel 99 is rejected by pure effect preparation.  Search considers the
  -- other coherent world, whose two same-key obligations merge and discharge
  -- as one driver call.
  committed = fibers.perform(Op.choice(
    configure_radio_op(99, 2),
    configure_radio_op(11, 3)
  ))
end)

assert(fallback == 'kept existing configuration')
assert(committed.channel == 11 and committed.power == 3)
assert(desired.value.channel == 11 and desired.value.power == 3)
assert(#driver_calls == 1)
assert(driver_calls[1].radio == 'uplink')
assert(driver_calls[1].config.channel == 11)
assert(driver_calls[1].config.power == 3)

print(fallback)
print('committed channel 11 at power 3 with one driver call')
