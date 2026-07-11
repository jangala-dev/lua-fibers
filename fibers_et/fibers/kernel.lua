-- Kernel aggregate for advanced users and embedders.

return {
  Runtime = require('fibers.kernel.runtime'),
  Interest = require('fibers.kernel.interest'),
  Exit = require('fibers.kernel.exit'),
  Protected = require('fibers.kernel.protected'),
  ScopeResult = require('fibers.kernel.scope_result'),
  TransactionNet = require('fibers.kernel.transaction_net'),
  Resources = require('fibers.kernel.resources'),
}
