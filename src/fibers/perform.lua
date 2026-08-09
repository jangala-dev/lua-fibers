-- The single current-runtime execution boundary.
--
-- Facility modules depend on this small function rather than on the application
-- facade.  Direct performing conveniences are exact tail calls to perform(op).

local Context = require('fibers.internal.context')

local function perform(option)
  local rt = Context.runtime
  if not rt then
    error('fibers.perform must be called from a running fiber', 2)
  end
  local scope = rt._current_fiber.scope
  if scope and type(scope.perform) == 'function' then
    return scope:perform(option)
  end
  return rt:perform(option)
end

return perform
