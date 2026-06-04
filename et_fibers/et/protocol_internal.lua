-- Compatibility shim for older tests/internal callers.
--
-- New code should import et.machine.kernel/frontier/commit or et.protocol
-- directly.  The resource-facing public contract remains et.protocol.

local Kernel = require('et.machine.kernel')
local Frontier = require('et.machine.frontier')
local Protocol = require('et.protocol')

return {
  Result = Kernel.Status,
  Util = Kernel.Util,
  Phase = Kernel.Phase,
  Origin = Frontier.Origin,
  Dependency = Frontier.Dependency,
  Consequence = Frontier.Consequence,
  Link = Protocol.Link,
  View = Frontier.View,
  Obligation = Frontier.Obligation,
  Values = Protocol.Values,
  Effect = Protocol.Effect,
}
