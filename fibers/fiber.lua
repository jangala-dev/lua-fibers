-- fibers/fiber.lua
---
-- Compatibility wrapper around fibers.runtime.
-- Existing code can continue to require 'fibers.fiber'.
-- @module fibers.fiber

local runtime = require 'fibers.runtime'

return {
    current_scheduler = runtime.current_scheduler,
    spawn             = runtime.spawn,
    now               = runtime.now,
    suspend           = runtime.suspend,
    yield             = runtime.yield,
    stop              = runtime.stop,
    main              = runtime.main,
}
