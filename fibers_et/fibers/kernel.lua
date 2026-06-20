-- Kernel aggregate for advanced users and embedders.

return {
  Runtime = require('fibers.kernel.runtime'),
  Wait = require('fibers.kernel.wait'),
  Certificate = require('fibers.kernel.certificate'),
  Exit = require('fibers.kernel.exit'),
  Protected = require('fibers.kernel.protected'),
}
