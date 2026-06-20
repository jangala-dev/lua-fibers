-- Kernel aggregate for advanced users and embedders.

return {
  Runtime = require('fibers.kernel.runtime'),
  Wait = require('fibers.kernel.wait'),
  Exit = require('fibers.kernel.exit'),
  Protected = require('fibers.kernel.protected'),
  TransactionNet = require('fibers.kernel.transaction_net'),
  Resources = require('fibers.kernel.resources'),
}
