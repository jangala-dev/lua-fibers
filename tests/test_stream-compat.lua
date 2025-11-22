--- Tests the Stream Compat implementation.
print('testing: fibers.stream.compat')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local fibers = require 'fibers'
local compat = require 'fibers.stream.compat'

print('selftest: lib.stream.compat')

local function main()
    _G.io.write('before\n')
    compat.install()
    _G.io.write('after\n')
    assert(_G.io == io)
    compat.uninstall()

    print('test: ok')
end

fibers.run(main)
