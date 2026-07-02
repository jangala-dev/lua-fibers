-- Scope settlement policy hooks.
--
-- A policy is carried by Scope and interpreted by fibers.scope.policy. It is
-- not a root-entry mechanism; fibers.run creates the root scope directly.

local Policy = {}

local Nursery = {}
Nursery.__index = Nursery

function Policy.nursery(opts)
  opts = opts or {}
  return setmetatable({ name = opts.name or 'nursery' }, Nursery)
end

function Nursery:on_scope_closing(_scope, _reason, _body_ok, _primary) return nil end
function Nursery:on_body_failure(_scope, _err) return nil end
function Nursery:on_child_exit(_scope, _task, exit)
  local Exit = require('fibers.kernel.exit')
  if Exit.is(exit) and exit.tag == 'failed' then return exit end
  return nil
end
function Nursery:on_child_failure(_scope, _reason, _exit) return nil end

return Policy
