package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

-- A collecting supervisor lets independent desktop services finish, records an
-- optional thumbnail failure, and still returns the healthy search index.

local fibers = require('fibers')
local closure = require('fibers.closure')

local workspace_report

local outer = fibers.try_run(function()
  return fibers.try_scope({
    name = 'workspace-services',
    closure = closure.supervisor({ child_failure = 'collect' }),
  }, function()
    fibers.spawn(function()
      error('thumbnail decoder rejected an optional preview', 0)
    end, 'optional-thumbnailer')

    local search_index = fibers.spawn(function()
      return 'workspace index healthy'
    end, 'search-index')

    return search_index:await()
  end)
end)

assert(outer.ok)
workspace_report = outer.values[1]
assert(workspace_report.ok)
assert(workspace_report:unpack() == 'workspace index healthy')
assert(#workspace_report.report.child_failures == 1)
print(workspace_report:unpack(), 'optional failures:', #workspace_report.report.child_failures)
