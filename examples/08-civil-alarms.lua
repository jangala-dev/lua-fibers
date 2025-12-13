-- civil-alarms.lua
--
-- Very simple civil-time helpers built on top of fibers.alarm.
-- This example trusts Lua's os.date / os.time for all civil-time logic.
--
-- It provides:
--   * daily_at(hour, min, sec?) -> Alarm that fires once per day at local HH:MM:SS
--   * next_at(hour, min, sec?)  -> Alarm that fires once at the next local HH:MM:SS

package.path = '../src/?.lua;' .. package.path

local fibers    = require 'fibers'
local alarm_mod = require 'fibers.alarm'

local perform = fibers.perform

----------------------------------------------------------------------
-- Internal helper: compute next local HH:MM:SS in epoch seconds
----------------------------------------------------------------------

--- Compute the next local HH:MM:SS occurrence, possibly using `last` for recurrence.
---@param hour integer  # 0..23
---@param min integer   # 0..59
---@param sec integer|nil  # 0..59 (default 0)
---@param last number|nil  # last fired epoch
---@param now number       # current epoch
---@return number          # next firing epoch
local function next_local_time_at(hour, min, sec, last, now)
  sec = sec or 0

  -- We rely entirely on os.date / os.time. This means:
  --   * Local time zone and DST come from the process environment.
  --   * Gaps/overlaps are handled as per the platform's C library.

  local t

  if last then
    -- Subsequent firing: "tomorrow at HH:MM:SS" relative to the last firing.
		t = os.date('*t', last)
  else
    -- First firing: choose between "today at HH:MM:SS" and "tomorrow at HH:MM:SS".
		t = os.date('*t', now)

    local past =
      t.hour > hour
      or (t.hour == hour and (
				t.min > min
				or (t.min == min and t.sec >= sec)
			))

    if past then
      t.day = t.day + 1
    end
  end

	-- Narrow os.date('*t', ...) to the structured date type for the type checker.
	---@cast t osdate
  t.hour, t.min, t.sec = hour, min, sec

  return os.time(t)
end

----------------------------------------------------------------------
-- One-shot: next local HH:MM:SS
----------------------------------------------------------------------

--- One-shot alarm that fires once at the next local HH:MM:SS.
---@param hour integer  # 0..23
---@param min integer   # 0..59
---@param sec integer|nil  # 0..59 (default 0)
---@param label? string
---@return Alarm
local function next_at(hour, min, sec, label)
	return alarm_mod.new {
		next_time = function (last, now)
      -- If we have already fired once, stop.
      if last ~= nil then
        return nil
      end
      return next_local_time_at(hour, min, sec, last, now)
    end,
    label = label or string.format(
			'next_%02d:%02d:%02d_local',
      hour, min, sec or 0
    ),
  }
end

----------------------------------------------------------------------
-- Recurring: daily at local HH:MM:SS
----------------------------------------------------------------------

--- Recurring alarm that fires once per day at local HH:MM:SS.
---@param hour integer  # 0..23
---@param min integer   # 0..59
---@param sec integer|nil  # 0..59 (default 0)
---@param label? string
---@return Alarm
local function daily_at(hour, min, sec, label)
	return alarm_mod.new {
		next_time = function (last, now)
      return next_local_time_at(hour, min, sec, last, now)
    end,
    label = label or string.format(
			'daily_%02d:%02d:%02d_local',
      hour, min, sec or 0
    ),
  }
end

----------------------------------------------------------------------
-- User code
----------------------------------------------------------------------

-- Install the wall-clock time source once at start-up.
alarm_mod.set_time_source(os.time)

--- Extract numeric hour/min/sec from an os.date('*t') table.
---@param t osdate
---@return integer hour
---@return integer min
---@return integer sec
local function civil_hms(t)
	-- tonumber() gives the type checker a plain number; assertions make failures explicit.
	local hour = assert(tonumber(t.hour), 'invalid hour from os.date')
	local min  = assert(tonumber(t.min), 'invalid min from os.date')
	local sec  = assert(tonumber(t.sec), 'invalid sec from os.date')
	return hour, min, sec
end

fibers.run(function ()
  local start_epoch = os.time()

  -- Create a one-off alarm at local HH:MM:SS+3.
  local oo_target = start_epoch + 3
	local oo_civil                = os.date('*t', oo_target)
	---@cast oo_civil osdate
	local oo_hour, oo_min, oo_sec = civil_hms(oo_civil)
	local oo_alarm                = next_at(oo_hour, oo_min, oo_sec)

  -- Wait for alarm to fire.
  local oo_fired, _, oo_fired_at = perform(oo_alarm:wait_op())

	print('fired =', oo_fired)
	print('scheduled local time  =', os.date('%X', oo_target))
	print('fired at local time   =', os.date('%X', oo_fired_at))
	print('delta seconds         =', os.difftime(oo_fired_at, start_epoch))

	-- Create a daily alarm at local HH:MM:SS+5.
  local d_target = start_epoch + 5
	local d_civil              = os.date('*t', d_target)
	---@cast d_civil osdate
	local d_hour, d_min, d_sec = civil_hms(d_civil)
	local d_alarm              = daily_at(d_hour, d_min, d_sec)

	-- Wait for alarm to fire.
	local d_fired, _, d_fired_at = perform(d_alarm:wait_op())

	print('fired =', d_fired)
	print('scheduled local time  =', os.date('%X', d_target))
	print('fired at local time   =', os.date('%X', d_fired_at))
	print('delta seconds         =', os.difftime(d_fired_at, start_epoch))
end)
