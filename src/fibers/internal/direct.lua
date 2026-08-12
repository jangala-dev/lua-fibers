-- Install exact direct twins for one-transaction `_op` methods.
-- Every installed `foo(...)` is exactly `perform(foo_op(...))`.

local perform = require('fibers.perform')

local M = {}

function M.install(class, names)
  for i = 1, #names do
    local name = names[i]
    local op_name = name .. '_op'
    class[name] = function(self, ...)
      return perform(self[op_name](self, ...))
    end
  end
  return class
end

function M.install_static(target, names)
  for i = 1, #names do
    local name = names[i]
    local op_name = name .. '_op'
    target[name] = function(...) return perform(target[op_name](...)) end
  end
  return target
end

return M
