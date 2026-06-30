-- Launch policies for the friendly facade.
--
-- A policy is an explicit launch-time choice for a root Scope. Policy is not a
-- second unit of work: it is carried by Scope.

local Scope = require('fibers.scope')
local Protected = require('fibers.kernel.protected')

local unpack_ = table.unpack or unpack
local Policy = {}

local Raw = {}
Raw.__index = Raw

function Raw:enter(runtime, parent)
  return Scope.new(self.name or 'raw', { runtime = runtime, parent = parent, policy = self })
end

function Raw:run_root(scope, fn, runtime)
  return fn(scope, runtime)
end

function Policy.raw(opts)
  opts = opts or {}
  return setmetatable({ name = opts.name or 'raw' }, Raw)
end

local Nursery = {}
Nursery.__index = Nursery

function Nursery:enter(runtime, parent)
  return Scope.new(self.name or 'nursery', { runtime = runtime, parent = parent, policy = self })
end

function Nursery:run_root(scope, fn)
  return scope:run(function(s)
    return fn(s)
  end)
end

function Policy.nursery(opts)
  opts = opts or {}
  return setmetatable({ name = opts.name or 'nursery' }, Nursery)
end


function Raw:on_scope_closing(_scope, _reason, _body_ok, _primary) return nil end
function Raw:on_body_failure(_scope, _err) return nil end
function Raw:on_child_exit(_scope, _task, _exit) return nil end
function Raw:on_child_failure(_scope, _reason, _exit) return nil end

function Nursery:on_scope_closing(_scope, _reason, _body_ok, _primary) return nil end

function Nursery:on_body_failure(_scope, _err) return nil end

function Nursery:on_child_exit(_scope, _task, exit)
  local Exit = require('fibers.kernel.exit')
  if Exit.is(exit) and exit.tag == 'failed' then return exit end
  return nil
end

function Nursery:on_child_failure(_scope, _reason, _exit) return nil end

return Policy
