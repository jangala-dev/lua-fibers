-- The single current-runtime execution boundary.
--
-- Facility modules depend on this small function rather than on the application
-- facade.  Direct performing conveniences are exact tail calls to perform(op).

local Runtime = require('fibers.runtime')

local function perform(option)
  local rt = Runtime.current()
  if not rt then
    error('fibers.perform must be called from a running fiber', 2)
  end
  local scope = Runtime.current_scope and Runtime.current_scope() or nil
  if scope and type(scope.perform) == 'function' then
    return scope:perform(option)
  end
  return rt:perform(option)
end

return perform
