package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local External = require('fibers.embed.external')
local fibers = require('fibers')
local FakeHandle = require('tests.support.fake_handle')
local FibersRuntime = require('fibers.runtime')
local Lifetime = require('fibers.lifetime')
local Lifetimes = require('tests.support.lifetimes')
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
  local scope = FibersScope.new( { runtime = rt, closure = FibersClosure.nursery() }):label('compound-failure-scope')
  rt:_spawn_raw(function()
    scope:run(function(s)
      local h = { label = 'compound-failure-owned' }
      Lifetime.define(h, { closure = {
        name = 'boom',
        finish_op = function() error('closure boom') end,
      } })
      fibers.perform(s:admit_op(h))
      error('body boom')
    end)
  end,  scope):label('compound-failure-root')
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
  local root = FibersScope.new( { runtime = rt, closure = FibersClosure.nursery() }):label('closure-hook-root')
  rt:_spawn_raw(function()
    root:run(function()
      fibers.scope({ closure = FibersClosure.running(closure) }, function()
        error('closure body failure')
      end)
    end)
  end,  root):label('closure-hook-root-fiber')
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
    local backend = FakeHandle.new({ label = 'safe-acquire-backend' })
    local stream =
      fibers.perform(Stream.open_op(backend, { read = true, write = true, label = 'safe-acquire-stream' }))
    owner_was_root = fibers.perform(root:has_custody_op(stream))
  end)
  assert_eq(owner_was_root, true, 'safe stream acquisition should use current scope')
end

-- Safe acquisition without a current scope is rejected; owner-first low-level
-- acquisition is explicit through the _in_op form.
do
  local backend = FakeHandle.new({ label = 'no-current-scope-backend' })
  local ok, err = pcall(function()
    Stream.open_op(backend, { read = true, write = true, label = 'no-current-scope-stream' })
  end)
  assert_eq(ok, false, 'safe acquisition should require a current scope or opts.scope')
  assert_truthy(tostring(err):match('current Scope'), 'error should explain missing current Scope')
end

-- Escaped handles are inert after their owning scope retires them.
do
  local stream, read_err
  local rt = FibersRuntime.new()
  local root = FibersScope.new( { runtime = rt, closure = FibersClosure.nursery() }):label('retired-authority-root')
  rt:_spawn_raw(function()
    root:run(function()
      fibers.scope(function()
        local backend = FakeHandle.new({ label = 'retired-authority-backend', input = 'x' })
        stream = fibers.perform(
          Stream.open_op(backend, { read = true, write = true, label = 'retired-authority-stream' })
        )
      end)
      local bytes, err = fibers.perform(stream:reader():read_some_op(1))
      read_err = err or bytes
    end)
  end,  root):label('retired-authority-root-fiber')
  drive(rt, 100)
  assert_eq(
    read_err,
    FibersFlow.Error.RETIRED,
    'read after scope retirement should fail with retired authority'
  )
end

-- Test-only store inspection confirms sealing while root Closure is in progress.
do
  local rt = FibersRuntime.new()
  local settled, feed = External.signal(rt)
  settled:label('hardening-settled')
  local scope = FibersScope.new( { runtime = rt, closure = FibersClosure.nursery() }):label('hardening-settling')
  local h = { label = 'hardening-settling-owned' }
  local state
  rt:_spawn_raw(function()
    scope:run(function(s)
      Lifetime.define(h, { closure = {
        name = 'wait',
        finish_op = function()
          return settled:wait_op():map(function() return true end)
        end,
      } })
      rt:perform(s:admit_op(h))
    end)
  end,  scope):label('hardening-settling-root')

  local st
  for _ = 1, 20 do
    st = rt:run()
    if st.tag == 'pending' then
      break
    end
  end
  state = Lifetimes.state(scope)
  assert_eq(state.sealed, true, 'scope should be sealed while Closure waits')
  assert_truthy(state.closure_phase ~= 'closed', 'scope should not be closed while Closure waits')
  feed:set(true)
  rt:run()
end

-- Stream.open_op constructs safe acquisition in the current scope.
do
  local owner_was_root = false
  fibers.run(function(root)
    local backend = FakeHandle.new({ label = 'friendly-stream-backend' })
    local stream =
      fibers.perform(Stream.open_op(backend, { read = true, write = true, label = 'friendly-stream' }))
    owner_was_root = fibers.perform(root:has_custody_op(stream))
  end)
  assert_eq(owner_was_root, true, 'Stream.open_op should bind to the current scope')
end

print('tests/test_scope_hardening.lua: ok')
