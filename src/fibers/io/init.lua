---Host-neutral I/O contracts and facilities.
---
---This module does not select or probe an operating-system backend. Require an
---explicit backend such as `fibers.io.nixio` or use `fibers.io.auto` in
---convenience applications.

return {
  Error = require('fibers.io.error'),
  Handle = require('fibers.io.handle'),
  Reactor = require('fibers.io.reactor'),
  Readiness = require('fibers.io.readiness'),
  Offer = require('fibers.io.offer'),
  Facility = require('fibers.io.facility'),
  Platform = require('fibers.io.platform'),
  Stream = require('fibers.io.stream'),
}
