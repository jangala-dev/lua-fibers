-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Go.

package.path = "../?.lua;" .. package.path

local fiber = require 'fibers.fiber'

local M = {}

setmetatable(M, {
    __call = function(_, fn, args)
        fiber.spawn(function ()
            fn(unpack(args or {}))
        end)
    end
})

return M