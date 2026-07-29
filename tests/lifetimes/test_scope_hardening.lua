package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local FakeHandle = require('tests.support.fake_handle')
local FibersRuntime = require('fibers.runtime')
local Lifetime = require('fibers.lifetime')
local FibersScope = require('fibers.scope')
local FibersFlow = require('fibers.resource.flow')
local FibersStream = require('fibers.io.stream')
local FibersClosure = require('fibers.closure')
local Stream = FibersStream
local function fail(msg)
  error(msg, 2)
end
local function assert_eq(a, b, msg)
  if a ~= b then
    fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end
local function assert_truthy(v, msg)
  if not v then
    fail(msg or 'expected truthy')
  end
end
local function drive(rt, limit)
  limit = limit or 100
  local st
  for _ = 1, limit do
    st = rt:run()
    if st.tag == 'idle' or st.tag == 'quiescent' then
      return st
    end
  end
  return st
end

-- Body failures and closure failures are reported together.  The body error
-- remains primary; cleanup failure is retained as a structured secondary.
do
  local rt = FibersRuntime.new()
  local scope = FibersScope.new('compound-failure-scope', { runtime = rt, closure = FibersClosure.nursery() })
  rt:spawn_raw(function()
    scope:run(function(s)
      local h = { name = 'compound-failure-owned' }
      Lifetime.define(h, {
        closure = {
          name = 'boom',
          finish_op = function()
            error('closure boom')
          end,
        },
      })
      fibers.perform(s:admit_op(h))
      error('body boom')
    end)
  end, 'compound-failure-root', scope)
  local ok, err = pcall(function()
    drive(rt, 100)
  end)
  assert_eq(ok, false, 'scope should fail')
  local report = FibersScope.is_report(err) and err or err.scope_report
  assert_truthy(
    FibersScope.is_report(report),
    'scope should raise a structured report when body and Closure both fail'
  )
  assert_truthy(tostring(report.primary):match('body boom'), 'body error should remain primary')
  assert_eq(report.secondary_count, 1, 'closure failure should be secondary')
  assert_truthy(
    tostring(report.secondaries[1]):match('closure boom'),
    'secondary should describe closure failure'
  )
end

-- Closure propagation hooks are first-class extension points rather than
-- hard-coded nursery behaviour.
do
  local seen_body_failure = false
  local closure = {
    on_body_result = function(_self, _parent, _state, body_ok, err)
      seen_body_failure = not body_ok and tostring(err):match('closure body failure') ~= nil
      return { seal = true }
    end,
  }
  local rt = FibersRuntime.new()
  local root = FibersScope.new('closure-hook-root', { runtime = rt, closure = FibersClosure.nursery() })
  rt:spawn_raw(function()
    root:run(function()
      fibers.scope({ closure = FibersClosure.running(closure) }, function()
        error('closure body failure')
      end)
    end)
  end, 'closure-hook-root-fibre', root)
  local ok = pcall(function()
    drive(rt, 100)
  end)
  assert_eq(ok, false, 'body failure should still propagate')
  assert_eq(seen_body_failure, true, 'Closure hook should observe body failure')
end

-- Safe acquisition binds to the current scope by default.
do
  local owner_was_root = false
  fibers.run(function(root)
    local backend = FakeHandle.new({ name = 'safe-acquire-backend' })
    local stream =
      fibers.perform(Stream.open_op(backend, { read = true, write = true, name = 'safe-acquire-stream' }))
    owner_was_root = fibers.perform(root:has_custody_op(stream))
  end)
  assert_eq(owner_was_root, true, 'safe stream acquisition should use current scope')
end

-- Safe acquisition without a current scope is rejected; owner-first low-level
-- acquisition is explicit through the _in_op form.
do
  local backend = FakeHandle.new({ name = 'no-current-scope-backend' })
  local ok, err = pcall(function()
    Stream.open_op(backend, { read = true, write = true, name = 'no-current-scope-stream' })
  end)
  assert_eq(ok, false, 'safe acquisition should require a current scope or opts.scope')
  assert_truthy(tostring(err):match('current Scope'), 'error should explain missing current Scope')
end

-- Escaped handles are inert after their owning scope retires them.
do
  local stream, read_err
  local rt = FibersRuntime.new()
  local root = FibersScope.new('retired-authority-root', { runtime = rt, closure = FibersClosure.nursery() })
  rt:spawn_raw(function()
    root:run(function()
      fibers.scope(function()
        local backend = FakeHandle.new({ name = 'retired-authority-backend', input = 'x' })
        stream = fibers.perform(
          Stream.open_op(backend, { read = true, write = true, name = 'retired-authority-stream' })
        )
      end)
      local bytes, err = fibers.perform(stream:reader():read_some_op(1))
      read_err = err or bytes
    end)
  end, 'retired-authority-root-fibre', root)
  drive(rt, 100)
  assert_eq(
    read_err,
    FibersFlow.Error.RETIRED,
    'read after scope retirement should fail with retired authority'
  )
end

-- inspect_op exposes sealed boundary facts while root closure is in
-- progress, without depending on a lifecycle phase enum.
do
  local rt = FibersRuntime.new()
  local settled, feed = rt:signal('hardening-settled')
  local scope = FibersScope.new('hardening-settling', { runtime = rt, closure = FibersClosure.nursery() })
  local h = { name = 'hardening-settling-owned' }
  local state
  rt:spawn_raw(function()
    scope:run(function(s)
      Lifetime.define(h, {
        closure = {
          name = 'wait',
          finish_op = function()
            return settled:wait_op():map(function()
              return true
            end)
          end,
        },
      })
      rt:perform(s:admit_op(h))
    end)
  end, 'hardening-settling-root', scope)

  local st
  for _ = 1, 20 do
    st = rt:run()
    if st.tag == 'pending' then
      break
    end
  end
  rt:spawn_raw(function()
    state = rt:perform(scope:inspect_op())
  end, 'hardening-settling-monitor')
  for _ = 1, 20 do
    st = rt:run()
    if state then
      break
    end
  end
  assert_truthy(state, 'monitor should read scope state')
  assert_eq(state.sealed, true, 'scope should expose sealed boundary fact')
  assert_eq(state.done, false, 'scope should not be done while Closure waits')
  feed:set(true)
  rt:run()
end

-- Stream.open_op constructs safe acquisition in the current scope.
do
  local owner_was_root = false
  fibers.run(function(root)
    local backend = FakeHandle.new({ name = 'friendly-stream-backend' })
    local stream =
      fibers.perform(Stream.open_op(backend, { read = true, write = true, name = 'friendly-stream' }))
    owner_was_root = fibers.perform(root:has_custody_op(stream))
  end)
  assert_eq(owner_was_root, true, 'Stream.open_op should bind to the current scope')
end

print('tests/test_scope_hardening.lua: ok')
