-- Transaction kernel aggregate for advanced users and embedders.
return {
  Runtime = require('fibers.kernel.runtime'),
  Machine = require('fibers.kernel.machine'),
  IR = require('fibers.kernel.ir'),
  Store = require('fibers.kernel.store'),
}
