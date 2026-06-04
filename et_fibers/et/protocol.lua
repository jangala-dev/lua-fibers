-- Public ET primitive protocol facade.
--
-- Resources should depend on this module, not on et.machine.*.

return {
  Link = require('et.protocol.link'),
  Values = require('et.protocol.values'),
  Effect = require('et.protocol.effect'),
}
