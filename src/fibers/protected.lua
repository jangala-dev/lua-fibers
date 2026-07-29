-- Yieldable protected calls for Fibers library and application code.
--
-- The implementation remains in fibers.internal.protected because it also
-- maintains coroutine identity for the Runtime.  This public module deliberately
-- exposes only the portable protected-call contract.

local Internal = require('fibers.internal.protected')

return {
  pcall = Internal.pcall,
  xpcall = Internal.xpcall,
}
