package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')

return function()
  do
    local _case = (function()
      package.path = table.concat({
        './?.lua', './?/init.lua', './?/?.lua',
        package.path,
      }, ';')
      
      local Result = require('et.kernel').Status
      local Op = require('et.op')
      local Runtime = require('et.runtime')
      local Cell = require('et.resources.cell')
      local Link = require('et.protocol').Link
      
      local function assert_eq(actual, expected, msg)
        if actual ~= expected then
          error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
        end
      end
      
      local function assert_status(x, tag, msg)
        if not x or x.tag ~= tag then
          error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2)
        end
        return x.value
      end
      
      local function test_runtime_cell_update_commits()
        local rt = Runtime.new()
        local c = Cell.new(0, 'runtime-cell-update')
        local result
        rt:spawn(function()
          result = rt:perform(c:update_op(Op, function(v) return v + 1 end))
        end, 'updater')
        assert_status(rt:run(), 'found')
        assert_eq(result, 1, 'perform returns update result')
        assert_eq(c.value, 1, 'commit applies cell update')
        assert_eq(c.version, 1, 'commit advances cell version')
        assert_eq(rt.stats.commits, 1, 'one commit recorded')
      end
      
      local function test_or_else_primary_wins_when_available()
        local rt = Runtime.new()
        local c = Cell.new(0, 'runtime-or-else-primary')
        local result
        rt:spawn(function()
          result = rt:perform(
            c:update_op(Op, function(v) return v + 1 end)
              :map(function(_) return 'primary' end)
              :or_else(Op.always('fallback'))
          )
        end, 'primary-wins')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'primary')
        assert_eq(c.value, 1, 'primary update committed')
      end
      
      local function test_or_else_fallback_when_primary_absent()
        local rt = Runtime.new()
        local result
        rt:spawn(function()
          result = rt:perform(Op.never():or_else(Op.always('fallback')))
        end, 'fallback')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'fallback')
        assert_eq(rt.stats.commits, 1, 'fallback still crosses commit certificate boundary')
      end
      
      local function test_stale_retry_two_cell_updates()
        local rt = Runtime.new()
        local c = Cell.new(0, 'runtime-stale-retry')
        local a, b
        rt:spawn(function()
          a = rt:perform(c:update_op(Op, function(v) return v + 1 end))
        end, 'stale-a')
        rt:spawn(function()
          b = rt:perform(c:update_op(Op, function(v) return v + 1 end))
        end, 'stale-b')
        assert_status(rt:run(), 'found')
        assert_eq(a, 1, 'first updater returns first value')
        assert_eq(b, 2, 'second updater retries and returns second value')
        assert_eq(c.value, 2, 'both cell updates commit')
        assert_eq(rt.stats.commits, 2, 'two commits recorded')
        assert(rt.stats.refreshes >= 1, 'stale frontier was refreshed')
      end
      
      local function test_stale_or_else_retries_primary_not_fallback()
        local rt = Runtime.new()
        local c = Cell.new(0, 'runtime-stale-or-else')
        local a, b
        rt:spawn(function()
          a = rt:perform(c:update_op(Op, function(v) return v + 1 end))
        end, 'stale-or-a')
        rt:spawn(function()
          b = rt:perform(
            c:update_op(Op, function(v) return v + 1 end)
              :map(function(_) return 'primary' end)
              :or_else(Op.always('fallback'))
          )
        end, 'stale-or-b')
        assert_status(rt:run(), 'found')
        assert_eq(a, 1)
        assert_eq(b, 'primary', 'stale primary retries; fallback is not justified by staleness')
        assert_eq(c.value, 2, 'primary branch update committed after refresh')
        assert(rt.stats.refreshes >= 1, 'or_else primary required stale refresh')
      end
      
      
      local function test_deferred_map_single_return_resolves_to_value()
        local rt = Runtime.new()
        local c = Cell.new(10, 'runtime-map-single')
        local result
        rt:spawn(function()
          result = rt:perform(c:get_op(Op):map(function(v) return v + 1 end))
        end, 'map-single')
        assert_status(rt:run(), 'found')
        assert_eq(result, 11, 'deferred map with one return resumes with the value, not a row table')
      end
      
      local function test_deferred_map_multiple_returns_resolve_to_row()
        local rt = Runtime.new()
        local c = Cell.new(10, 'runtime-map-multi')
        local a, b
        rt:spawn(function()
          a, b = rt:perform(c:get_op(Op):map(function(v) return v + 1, v + 2 end))
        end, 'map-multi')
        assert_status(rt:run(), 'found')
        assert_eq(a, 11, 'first deferred map return is spliced into root row')
        assert_eq(b, 12, 'second deferred map return is spliced into root row')
      end
      
      local function test_stale_certificate_without_stale_frontier_is_fatal()
        local BadClass = Link.resource {
          name = 'bad-stale-prepare',
          construct = function(self)
            self.label = 'bad-stale-prepare'
            self.version = 0
          end,
          snapshot = function(self) return { resource = self, version = self.version } end,
          initial = function(_self, snap) return { base_version = snap.version } end,
          claim = function(_self, _snap, fragment, _claim, ctx)
            return ctx:accept(fragment, true)
          end,
          merge = function(_self, _snap, request, _ctx)
            return (request.fragments or {})[1] or request.base
          end,
          prepare = function(self, _fragment, ctx)
            return ctx:stale({ self }, 'bad resource reports stale during prepare without invalidating frontier')
          end,
        }
        local Bad = BadClass.new()
      
        local rt = Runtime.new()
        local result
        rt:spawn(function()
          result = rt:perform(Op.access(Bad, { tag = 'go' }))
        end, 'bad-stale')
        local status = rt:run()
        assert_eq(status.tag, 'fatal', 'stale certificate without any refreshable frontier is fatal')
        assert(tostring(status.reason):match('stale certificate'), status.reason)
        assert_eq(result, nil, 'root is not resumed after fatal stale-certification bug')
      end
      
      return function()
        test_runtime_cell_update_commits()
        test_deferred_map_single_return_resolves_to_value()
        test_deferred_map_multiple_returns_resolve_to_row()
        test_stale_certificate_without_stale_frontier_is_fatal()
        test_or_else_primary_wins_when_available()
        test_or_else_fallback_when_primary_absent()
        test_stale_retry_two_cell_updates()
        test_stale_or_else_retries_primary_not_fallback()
        print('runtime resource retry cases: ok')
      end
    end)()
    _case()
  end
  do
    local _case = (function()
      package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
      
      local Op = require('et.op')
      local Runtime = require('et.runtime')
      local Cell = require('et.resources.cell')
      local Link = require('et.protocol').Link
      local Result = require('et.kernel').Status
      local Phase = require('et.kernel').Phase
      local Util = require('et.kernel').Util
      local Dependency = require('et.kernel').Dependency
      
      local function assert_eq(actual, expected, msg)
        if actual ~= expected then error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
      end
      
      local function assert_status(x, tag, msg)
        if not x or x.tag ~= tag then error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end end
      
      local Waiter = Link.resource {
        name = 'waiter',
        construct = function(self, label)
          self.id = label or 'waiter'
          self.version = 0
          self.ready = false
          self.publishes = 0
          self.unpublishes = 0
        end,
        snapshot = function(self) return { resource = self, version = self.version, ready = self.ready } end,
        initial = function(_self, snap) return { base_version = snap.version, ready = snap.ready, written = false } end,
        claim = function(self, snap, fragment, claim, ctx)
          local kind = claim.kind or 'access'
          local request = claim.request or claim.payload or claim
          if kind == 'await' then
            if request.tag ~= 'ready' then return ctx:fatal('unknown external wait') end
            if snap.ready then return ctx:ready('observed-ready') end
            return ctx:pending_on_self('not ready')
          end
          if fragment.base_version ~= snap.version then return ctx:stale({ self }, 'waiter stale') end
          if request.tag == 'bump' then
            return ctx:accept({ base_version = snap.version, ready = fragment.ready, written = true }, 'bumped')
          elseif request.tag == 'ready' then
            return ctx:accept({ base_version = snap.version, ready = true, written = true }, 'ready')
          end
          return ctx:fatal('unknown waiter local request')
        end,
        merge = function(self, snap, request, ctx)
          local fragments = request.fragments or {}
          if request.kind == 'project' then
            local base, full = request.base, fragments[1]
            if base.base_version ~= snap.version or full.base_version ~= snap.version then return ctx:stale({ self }, 'waiter stale') end
            if full.written then return { base_version = snap.version, ready = full.ready, written = true } end
            return nil
          elseif request.kind == 'extend' then
            local prefix = request.base
            for i=1,#fragments do
              local delta = fragments[i]
              if prefix.base_version ~= snap.version or delta.base_version ~= snap.version then return ctx:stale({ self }, 'waiter stale') end
              if delta.written then prefix = { base_version = snap.version, ready = delta.ready, written = true } end
            end
            return prefix
          end
          local acc = request.base
          for i=1,#fragments do
            local right = fragments[i]
            if acc == nil then acc = right
            else
              if acc.base_version ~= snap.version or right.base_version ~= snap.version then return ctx:stale({ self }, 'waiter stale') end
              if right.written then acc = right end
            end
          end
          return acc
        end,
        prepare = function(self, fragment, ctx)
          if fragment.base_version ~= self.version then return ctx:stale({ self }, 'waiter prepare stale') end
          local r = self
          return ctx:prepared({
            resource = r,
            dirty = fragment.written and { r } or {},
            consequences = { transaction = {}, resource = {}, obligation = {} },
            apply = function(commit_token)
              Phase.require(commit_token, 'commit')
              if fragment.written then r.ready = fragment.ready; r.version = r.version + 1 end
            end,
          })
        end,
      }
      function Waiter:bump_op(OpModule) return OpModule.access(self, { tag = 'bump' }) end
      function Waiter:make_ready_op(OpModule) return OpModule.access(self, { tag = 'ready' }) end
      function Waiter:await_ready_op(OpModule) return OpModule.await(self, { tag = 'ready' }) end
      
      local function wait_host()
        return {
          watch = function(_, wait)
            if wait and wait.resource then wait.resource.publishes = (wait.resource.publishes or 0) + 1 end
            return Result.found(true)
          end,
          unwatch = function(_, wait)
            if wait and wait.resource then wait.resource.unpublishes = (wait.resource.unpublishes or 0) + 1 end
            return Result.found(true)
          end,
        }
      end
      
      local function test_deadlock_only_at_fixpoint()
        local rt = Runtime.new({ quiet_deadlock = true, host = wait_host() })
        local ch = require('et.resources.channel').new('m9-deadlock')
        rt:spawn(function() rt:perform(ch:get_op(Op)) end, 'lonely-recv')
        local st = rt:run()
        assert_eq(st.tag, 'absent', 'no external wait and no candidate gives true quiescent absence')
        assert(rt.stats.fixpoint_iterations > 0, 'scheduler attempted fixpoint search before reporting absence')
      end
      
      local function test_dirty_local_resource_marks_dependent_frontier_stale()
        local rt = Runtime.new()
        local c = Cell.new(0, 'm9-dirty-cell')
        local a, b
        rt:spawn(function() a = rt:perform(c:update_op(Op, function(v) return v + 1 end)) end, 'm9-a')
        rt:spawn(function() b = rt:perform(c:update_op(Op, function(v) return v + 1 end)) end, 'm9-b')
        assert_status(rt:run(), 'found')
        assert_eq(c.value, 2)
        assert(rt.stats.refreshes >= 1, 'dirty local resource made the other frontier stale')
        assert(rt.stats.dirty_marks >= 1, 'commit recorded dirty resource marks')
        assert_eq(a, 1)
        assert_eq(b, 2)
      end
      
      local function test_external_waits_survive_refresh()
        local rt = Runtime.new({ quiet_deadlock = true, host = wait_host() })
        local w = Waiter.new('m9-external')
        local bumped
        rt:spawn(function() rt:perform(w:await_ready_op(Op)) end, 'm9-await')
        rt:spawn(function() bumped = rt:perform(w:bump_op(Op)) end, 'm9-bump')
        local st = rt:run()
        assert_eq(st.tag, 'pending', 'external wait remains pending instead of being reported as deadlock')
        assert_eq(bumped, 'bumped')
        assert(rt.stats.refreshes >= 1, 'dirty external dependency refreshed the waiting frontier')
        assert_eq(w.publishes, 2, 'external wait was re-published after refresh')
        assert_eq(w.unpublishes, 1, 'old external wait was unpublished during refresh')
        local count = 0
        for _ in pairs(rt.external_waits) do count = count + 1 end
        assert_eq(count, 1, 'one current external wait survives refresh')
      end
      
      local function test_external_wait_can_become_ready_after_refresh()
        local rt = Runtime.new({ host = wait_host() })
        local w = Waiter.new('m9-external-ready')
        local got, ready
        rt:spawn(function() got = rt:perform(w:await_ready_op(Op)) end, 'm9-await-ready')
        rt:spawn(function() ready = rt:perform(w:make_ready_op(Op)) end, 'm9-make-ready')
        local st = rt:run()
        assert_status(st, 'found')
        assert_eq(ready, 'ready')
        assert_eq(got, 'observed-ready')
        assert(rt.stats.refreshes >= 1, 'waiter refreshed after ready transition')
        local count = 0
        for _ in pairs(rt.external_waits) do count = count + 1 end
        assert_eq(count, 0, 'external wait registration removed after commit')
      end
      
      
      
      local function test_unrelated_dirty_resource_does_not_refresh_unrelated_frontier()
        local rt = Runtime.new({ quiet_deadlock = true, host = wait_host() })
        local waiting = Waiter.new('m9-unrelated-wait')
        local other = Waiter.new('m9-unrelated-other')
        local bumped
        rt:spawn(function() rt:perform(waiting:await_ready_op(Op)) end, 'm9-unrelated-await')
        rt:spawn(function() bumped = rt:perform(other:bump_op(Op)) end, 'm9-unrelated-bump')
        local st = rt:run()
        assert_eq(st.tag, 'pending', 'unrelated dirty resource leaves external wait pending')
        assert_eq(bumped, 'bumped')
        assert_eq(rt.stats.refreshes, 0, 'dependency index does not refresh unrelated frontier')
        assert_eq(waiting.publishes, 1, 'unrelated dirty resource does not republish external wait')
        assert_eq(waiting.unpublishes, 0, 'unrelated dirty resource does not unpublish external wait')
      end
      
      local function test_external_dirty_mark_drives_fixpoint_refresh()
        local rt = Runtime.new({ quiet_deadlock = true, host = wait_host() })
        local w = Waiter.new('m9-manual-dirty')
        local got
        rt:spawn(function() got = rt:perform(w:await_ready_op(Op)) end, 'm9-manual-await')
        local first = rt:run()
        assert_eq(first.tag, 'pending', 'initial external wait is pending')
        w.ready = true
        w.version = w.version + 1
        rt:mark_dirty({ w }, 'test external event')
        local second = rt:run()
        assert_status(second, 'found')
        assert_eq(got, 'observed-ready', 'manual dirty mark refreshes dependent wait and commits')
        assert(rt.stats.refreshes >= 1, 'manual dirty mark produced frontier refresh')
      end
      
      local function test_or_else_primary_retries_in_fixpoint()
        local rt = Runtime.new()
        local c = Cell.new(0, 'm9-or-else')
        local a, b
        rt:spawn(function() a = rt:perform(c:update_op(Op, function(v) return v + 1 end)) end, 'm9-or-a')
        rt:spawn(function()
          b = rt:perform(c:update_op(Op, function(v) return v + 1 end):map(function() return 'primary' end):or_else(Op.always('fallback')))
        end, 'm9-or-b')
        assert_status(rt:run(), 'found')
        assert_eq(a, 1)
        assert_eq(b, 'primary')
        assert_eq(c.value, 2)
      end
      
      return function()
        test_deadlock_only_at_fixpoint()
        test_dirty_local_resource_marks_dependent_frontier_stale()
        test_external_waits_survive_refresh()
        test_external_wait_can_become_ready_after_refresh()
        test_unrelated_dirty_resource_does_not_refresh_unrelated_frontier()
        test_external_dirty_mark_drives_fixpoint_refresh()
        test_or_else_primary_retries_in_fixpoint()
        print('runtime fixpoint cases: ok')
      end
    end)()
    _case()
  end
  print('runtime/engine tests: ok')
end
