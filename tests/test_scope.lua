--- Tests the Scope implementation.
print("test: fibers.scope")

-- look one level up
package.path = "../?.lua;" .. package.path

local runtime = require "fibers.runtime"
local scope   = require "fibers.scope"

local function test_outside_fibers()
    local root = scope.root()

    -- current() outside any fibre should be the root (process-wide current scope)
    assert(scope.current() == root, "outside fibres, current() should be root")

    local outer_scope
    local inner_scope

    scope.run(function(s)
        outer_scope = s

        -- Inside run, current() should be this child scope
        assert(scope.current() == s, "inside scope.run, current() should be child scope")
        assert(s:parent() == root, "outer scope parent must be root")

        -- root should see this child in its children list
        local rc = root:children()
        assert(#rc == 1 and rc[1] == s, "root:children() should contain outer scope")

        -- Nested run creates a grandchild of s
        scope.run(function(child2)
            inner_scope = child2
            assert(scope.current() == child2, "inside nested run, current() should be nested child")
            assert(child2:parent() == s, "nested scope parent must be outer scope")

            local sc = s:children()
            assert(#sc == 1 and sc[1] == child2, "outer scope children() should contain nested scope")
        end)

        -- After nested run, current() should be back to the outer scope
        assert(scope.current() == s, "after nested run, current() should be outer scope again")
    end)

    assert(outer_scope ~= nil, "outer_scope should have been set")
    assert(inner_scope ~= nil, "inner_scope should have been set")
    assert(outer_scope ~= inner_scope, "outer and inner scopes must differ")

    -- After scope.run returns, current() outside fibres should be root again
    assert(scope.current() == scope.root(), "after scope.run, current() should be root outside fibres")
end

local function test_inside_fibers()
    local root = scope.root()

    local child_in_fiber
    local grandchild_in_fiber

    -- Spawn a fibre anchored to the root scope.
    root:spawn(function(s)
        -- In this fibre, s is the scope used for spawn -> root
        assert(s == root, "spawn(fn) on root should pass root as scope")
        assert(scope.current() == root, "inside spawned fibre, current() should be root initially")

        -- Create a child scope inside the fibre
        scope.run(function(child)
            child_in_fiber = child
            assert(scope.current() == child, "inside scope.run in fibre, current() should be child")
            assert(child:parent() == root, "child-in-fibre parent must be root")

            -- Create a grandchild scope
            scope.run(function(grandchild)
                grandchild_in_fiber = grandchild
                assert(scope.current() == grandchild, "inside nested run in fibre, current() should be grandchild")
                assert(grandchild:parent() == child, "grandchild parent must be child")
            end)

            -- After nested run, current() should be back to child
            assert(scope.current() == child, "after nested run in fibre, current() should be child again")
        end)

        -- After inner run, current() should be back to root for this fibre
        assert(scope.current() == root, "after scope.run in fibre, current() should be root again")

        -- Stop the scheduler once all fibre-local tests have run
        runtime.stop()
    end)

    -- Drive the scheduler so the spawned fibre runs
    runtime.main()

    -- After main() returns we are back outside fibres;
    -- current() should again be the process-wide current scope (root).
    assert(scope.current() == root, "after runtime.main, current() outside fibres should be root")

    -- Check that scopes created inside the fibre were recorded
    assert(child_in_fiber ~= nil, "child_in_fiber should have been set")
    assert(grandchild_in_fiber ~= nil, "grandchild_in_fiber should have been set")
    assert(child_in_fiber:parent() == root, "child_in_fiber parent must be root")
    assert(grandchild_in_fiber:parent() == child_in_fiber, "grandchild_in_fiber parent must be child_in_fiber")

    -- Check that root children include both the outer test scope
    -- (from test_outside_fibers) and the child created in this fibre.
    local rc = root:children()
    assert(#rc >= 2, "root should have at least two children by now")
    local found_child = false
    for _, s in ipairs(rc) do
        if s == child_in_fiber then
            found_child = true
            break
        end
    end
    assert(found_child, "root:children() should contain child_in_fiber")
end

local function main()
    io.stdout:write("Running scope tests...\n")
    test_outside_fibers()
    test_inside_fibers()
    io.stdout:write("OK\n")
end

main()
