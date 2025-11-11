--- Tests the Stream Compat implementation.
print('testing: fibers.stream.compat')

-- look one level up
package.path = "../src/?.lua;" .. package.path

local compat = require 'fibers.stream.compat'

print('selftest: lib.stream.compat')

_G.io.write('before\n')
compat.install()
_G.io.write('after\n')
assert(_G.io == io)
compat.uninstall()

print('test: ok')
