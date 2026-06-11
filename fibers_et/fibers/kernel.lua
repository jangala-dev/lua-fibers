-- Kernel aggregate for advanced users and embedders.

return {
  Runtime = require('fibers.kernel.runtime'),
  Wait = require('fibers.kernel.wait'),
  ObservationJournal = require('fibers.kernel.observation_journal'),
  Exit = require('fibers.kernel.exit'),
  Protected = require('fibers.kernel.protected'),
}
