-- Copyright Jangala

local posix_time = require 'posix.time'

local function monotonic_float()
    local a = posix_time.clock_gettime(posix_time.CLOCK_MONOTONIC)
    return a.tv_sec + a.tv_nsec/1e9
end

local function realtime_float()
    local a = posix_time.clock_gettime(posix_time.CLOCK_REALTIME)
    return a.tv_sec + a.tv_nsec/1e9
end

local function sleep_float(secs)
    local decimal = secs % 1
    posix_time.nanosleep({tv_sec=secs-decimal, tv_nsec=decimal*1e9})
end

return {
    monotonic_float = monotonic_float,
    realtime_float = realtime_float,
    sleep_float = sleep_float
}