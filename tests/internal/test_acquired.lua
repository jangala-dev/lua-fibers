package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua',
  './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local Acquired = require('fibers.io.internal.acquired')

local closed = {}
local function closer(value, reason)
  closed[#closed + 1] = value .. ':' .. tostring(reason)
  return true
end

local guard = Acquired.new()
assert(guard:hold('one', 'a', closer) == 'a')
assert(guard:hold('two', 'b', closer) == 'b')
assert(guard:release('one', 'a') == 'a')
assert(guard:close('done'))
assert(#closed == 1 and closed[1] == 'b:done')

-- Cleanup is reverse acquisition order.
closed = {}
guard = Acquired.new()
guard:hold('one', 'a', closer)
guard:hold('two', 'b', closer)
assert(guard:close('rollback'))
assert(closed[1] == 'b:rollback' and closed[2] == 'a:rollback')

-- Yieldable protected extent closes unreleased values when setup unwinds.
closed = {}
local ok, err = pcall(function()
  Acquired.run(function(acquired)
    acquired:hold('value', 'x', closer)
    error('setup failed')
  end)
end)
assert(not ok and tostring(err):match('setup failed'))
assert(closed[1] and closed[1]:match('^x:'))

-- Released values are adopted and are not closed by the lexical guard.
closed = {}
local value = Acquired.run(function(acquired)
  acquired:hold('value', 'x', closer)
  return acquired:release('value', 'x')
end)
assert(value == 'x' and #closed == 0)

print('tests/internal/test_acquired.lua: ok')
