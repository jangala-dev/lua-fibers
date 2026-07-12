-- Run the protected-call suite with the coroutine-backed implementation in a
-- fresh interpreter.  Do not include this file in tests/run_all.lua.
package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

_G.__FIBERS_PROTECTED_FORCE_FALLBACK = true
_G.__FIBERS_PROTECTED_EXPECT_NATIVE = false

return dofile('tests/test_protected.lua')
