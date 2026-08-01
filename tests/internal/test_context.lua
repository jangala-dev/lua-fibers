package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Context = require('fibers.internal.context')

assert(Context.current_runtime() == nil, 'runtime context leaked between tests')
assert(Context.current_scope() == nil, 'scope context leaked between tests')

local runtime_a, scope_a = {}, {}
local runtime_b, scope_b = {}, {}
local outer = Context.enter(runtime_a, scope_a)
assert(Context.current_runtime() == runtime_a)
assert(Context.current_scope() == scope_a)

local inner = Context.enter(runtime_b, scope_b)
assert(Context.current_runtime() == runtime_b)
assert(Context.current_scope() == scope_b)
Context.set_scope(scope_a)
assert(Context.current_scope() == scope_a)
local ok = pcall(Context.leave, outer)
assert(ok == false, 'context tokens must be left in stack order')
Context.leave(inner)
assert(Context.current_runtime() == runtime_a)
assert(Context.current_scope() == scope_a)
Context.leave(outer)
assert(Context.current_runtime() == nil)
assert(Context.current_scope() == nil)

-- The direct perform boundary must remain lighter than the Runtime module.
local saved_runtime = package.loaded['fibers.runtime']
local saved_perform = package.loaded['fibers.perform']
package.loaded['fibers.runtime'] = nil
package.loaded['fibers.perform'] = nil
local perform = require('fibers.perform')
assert(type(perform) == 'function')
assert(package.loaded['fibers.runtime'] == nil, 'fibers.perform must not load the Runtime implementation')
package.loaded['fibers.perform'] = saved_perform or perform
package.loaded['fibers.runtime'] = saved_runtime

print('tests/internal/test_context.lua: ok')
return true
