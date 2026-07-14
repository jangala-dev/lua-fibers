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
local FibersRuntime = require('fibers.runtime')
local FibersRegion = require('fibers.lifetime.region')
local FibersScope = require('fibers.scope')
local FibersFlow = require('fibers.internal.flow')
local FibersStream = require('fibers.stream')
local FibersPolicy = require('fibers.policy')
local Stream = FibersStream
local Fake = Stream.backend.Fake

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

-- Body failures and settlement failures are reported together.  The body error
-- remains primary; cleanup failure is retained as a structured secondary.
do
  local rt = FibersRuntime.new()
  local scope =
    FibersScope.new('compound-failure-scope', { runtime = rt, policy = FibersPolicy.nursery() })
  rt:spawn_raw(function()
    scope:run(function(s)
      local h = FibersRegion.handle('compound-failure-owned')
      fibers.perform(s:raw_region():admit_op(FibersRegion.Owned.item(h, function()
        error('settlement boom')
      end, { settle_name = 'boom' })))
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
    'scope should raise a structured report when body and settlement both fail'
  )
  assert_truthy(tostring(report.primary):match('body boom'), 'body error should remain primary')
  assert_eq(report.secondary_count, 1, 'settlement failure should be secondary')
  assert_truthy(
    tostring(report.secondaries[1]):match('settlement boom'),
    'secondary should describe settlement failure'
  )
end

-- Policy hooks are first-class scope extension points rather than hard-coded
-- nursery behaviour.
do
  local seen_body_failure = false
  local policy = {
    on_body_failure = function(_self, _scope, err)
      seen_body_failure = tostring(err):match('policy body failure') ~= nil
      return true
    end,
  }
  local rt = FibersRuntime.new()
  local root =
    FibersScope.new('policy-hook-root', { runtime = rt, policy = FibersPolicy.nursery() })
  rt:spawn_raw(function()
    root:run(function()
      fibers.scope({ policy = policy }, function()
        error('policy body failure')
      end)
    end)
  end, 'policy-hook-root-fibre', root)
  local ok = pcall(function()
    drive(rt, 100)
  end)
  assert_eq(ok, false, 'body failure should still propagate')
  assert_eq(seen_body_failure, true, 'policy hook should observe body failure')
end

-- Safe acquisition binds to the current scope by default.
do
  local owner_was_root = false
  fibers.run(function(root)
    local backend = Fake.new({ name = 'safe-acquire-backend' })
    local stream = fibers.perform(Stream.open_backend_op(backend, { name = 'safe-acquire-stream' }))
    owner_was_root = stream.owner == root:raw_region()
  end)
  assert_eq(owner_was_root, true, 'safe stream acquisition should use current scope')
end

-- Safe acquisition without a current scope is rejected; owner-first low-level
-- acquisition is explicit through the _in_op form.
do
  local backend = Fake.new({ name = 'no-current-scope-backend' })
  local ok, err = pcall(function()
    Stream.open_backend_op(backend, { name = 'no-current-scope-stream' })
  end)
  assert_eq(ok, false, 'safe acquisition should require a current scope or opts.owner')
  assert_truthy(tostring(err):match('current Scope'), 'error should explain missing current Scope')
end

-- Escaped handles are inert after their owning scope retires them.
do
  local stream, read_err
  local rt = FibersRuntime.new()
  local root =
    FibersScope.new('retired-authority-root', { runtime = rt, policy = FibersPolicy.nursery() })
  rt:spawn_raw(function()
    root:run(function()
      fibers.scope(function()
        local backend = Fake.new({ name = 'retired-authority-backend', input = 'x' })
        stream =
          fibers.perform(Stream.open_backend_op(backend, { name = 'retired-authority-stream' }))
      end)
      local bytes, err = fibers.perform(stream:reader():read_op(1))
      read_err = err or bytes
    end)
  end, 'retired-authority-root-fibre', root)
  drive(rt, 100)
  assert_eq(
    read_err,
    FibersFlow.Errors.RETIRED,
    'read after scope retirement should fail with retired authority'
  )
end

-- inspect_op exposes sealed boundary facts while root settlement is in
-- progress, without depending on a lifecycle phase enum.
do
  local rt = FibersRuntime.new()
  local settled, feed = rt:signal('hardening-settled')
  local scope =
    FibersScope.new('hardening-settling', { runtime = rt, policy = FibersPolicy.nursery() })
  local h = FibersRegion.handle('hardening-settling-owned')
  local state
  rt:spawn_raw(function()
    scope:run(function(s)
      rt:perform(s:raw_region():admit_op(FibersRegion.Owned.item(h, function()
        return settled:wait_op():map(function()
          return true
        end)
      end, { settle_name = 'wait' })))
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
  assert_eq(state.done, false, 'scope should not be done while settlement waits')
  feed:set(true)
  rt:run()
end

-- Stream.open_backend_op constructs safe acquisition in the current scope.
do
  local owner_was_root = false
  fibers.run(function(root)
    local backend = Fake.new({ name = 'friendly-stream-backend' })
    local stream = fibers.perform(Stream.open_backend_op(backend, { name = 'friendly-stream' }))
    owner_was_root = stream.owner == root:raw_region()
  end)
  assert_eq(owner_was_root, true, 'Stream.open_backend_op should bind to the current scope')
end

print('tests/test_scope_hardening.lua: ok')
