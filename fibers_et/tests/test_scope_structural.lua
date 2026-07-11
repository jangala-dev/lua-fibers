package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')

local function fail(msg) error(msg, 2) end
local function assert_eq(a, b, msg) if a ~= b then fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_truthy(v, msg) if not v then fail(msg or 'expected truthy') end end

-- Inline scopes are same-fibre resource boundaries. Owned roots admitted inside
-- the scope are retired on normal exit without per-resource defer/finaliser code.
do
  local retired = 0
  local h = fibers.Region.handle('inner-owned', {
    settle = function()
      return fibers.always(true):map(function()
        retired = retired + 1
        return true
      end)
    end,
    settle_name = 'test-retire',
  })
  local owner_after_inner
  fibers.run(function()
    fibers.scope(function(scope)
      fibers.perform(scope:admit_op(h))
      assert_truthy(fibers.perform(scope:owns_op(h)), 'inner scope should own admitted handle')
    end)
    owner_after_inner = h.owner
  end)
  assert_eq(owner_after_inner, nil, 'scope exit should release the handle owner')
  assert_eq(retired, 1, 'scope exit should run the settlement protocol once')
end

-- Handoff is the explicit escape hatch. Returning or retaining a Lua table does
-- not transfer ownership; a transactionally handed-off root survives the inner
-- scope and is later retired by the receiver.
do
  local retired = 0
  local h = fibers.Region.handle('promoted-owned', {
    settle = function()
      return fibers.always(true):map(function()
        retired = retired + 1
        return true
      end)
    end,
    settle_name = 'test-retire',
  })
  local owned_by_root_after_inner
  fibers.run(function(root)
    fibers.scope(function(scope)
      fibers.perform(scope:raw_region():admit_op(h))
      fibers.perform(scope:move_op(h, root))
    end)
    owned_by_root_after_inner = h.owner == root:raw_region()
  end)
  assert_eq(owned_by_root_after_inner, true, 'move should transfer ownership to the root scope')
  assert_eq(h.owner, nil, 'root scope exit should retire the handed-off handle')
  assert_eq(retired, 1, 'the handed-off handle should still settle exactly once')
end

-- Current scope is restored after suspension, so safe acquisition/admission after
-- a blocking operation still attaches to the intended inline scope.
do
  local h = fibers.Region.handle('post-suspend-owned')
  local owned_inside
  fibers.run(function()
    local ch = fibers.Rendezvous.new('scope-stack-check')
    fibers.spawn(function()
      fibers.perform(ch:put_op('go'))
    end, 'scope-stack-sender')
    fibers.scope(function(scope)
      fibers.perform(ch:get_op())
      fibers.perform(scope:raw_region():admit_op(h))
      owned_inside = fibers.perform(scope:owns_op(h))
    end)
  end)
  assert_eq(owned_inside, true, 'current scope should survive suspension and resume')
  assert_eq(h.owner, nil, 'post-suspension owned root should be retired on scope exit')
end

print('tests/test_scope_structural.lua: ok')
