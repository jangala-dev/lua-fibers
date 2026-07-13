-- Trusted kernel aggregate for embedders and facility authors.
--
-- The production search machine and instrumentation implementation remain
-- internal. Require their modules directly only within the Fibers repository.
return {
  Runtime = require('fibers.kernel.runtime'),
  IR = require('fibers.kernel.ir'),
  Store = require('fibers.kernel.store'),
}
