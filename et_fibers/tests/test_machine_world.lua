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
      local Channel = require('et.resources.channel')
      local Cell = require('et.resources.cell')
      local Link = require('et.protocol').Link
      local View = require('et.machine.frontier').View
      local Frontier = require('et.machine.frontier').Frontier
      local ProofSearch = require('et.machine.proofnet')
      local Phase = require('et.kernel').Phase
      
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
      
      local function test_open_bind_after_claim_completion_continues_root()
        local rt = Runtime.new()
        local ch = Channel.new('world-bind-claim_completion')
        local sent, received
        rt:spawn(function()
          sent = rt:perform(ch:put_op(Op, 'payload'))
        end, 'bind-sender')
        rt:spawn(function()
          received = rt:perform(ch:get_op(Op):and_then(function(x)
            return Op.always(x .. '-bound')
          end))
        end, 'bind-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(sent, true, 'send commits')
        assert_eq(received, 'payload-bound', 'bind continuation runs after match assignment')
      end
      
      local function test_open_bind_can_introduce_later_claim_completion()
        local rt = Runtime.new()
        local first = Channel.new('world-bind-first')
        local second = Channel.new('world-bind-second')
        local s1, s2, result
        rt:spawn(function()
          s1 = rt:perform(first:put_op(Op, 'A'))
        end, 'first-sender')
        rt:spawn(function()
          s2 = rt:perform(second:put_op(Op, 'B'))
        end, 'second-sender')
        rt:spawn(function()
          result = rt:perform(first:get_op(Op):and_then(function(a)
            return second:get_op(Op):map(function(b) return a .. b end)
          end))
        end, 'sequential-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(s1, true, 'first send commits')
        assert_eq(s2, true, 'second send commits')
        assert_eq(result, 'AB', 'continuation-introduced claim_completion commits in same candidate world')
        assert_eq(rt.stats.commits, 1, 'both claim_completion commits are one Eventful Transaction')
      end
      
      local function test_match_alternative_rejected_candidate_does_not_reject_other_match()
        local rt = Runtime.new({ quiet_deadlock = true })
        local ch = Channel.new('world-match-alternatives')
        local c = Cell.new(0, 'world-match-cell')
        local bad_sender, good_sender, receiver
      
        rt:spawn(function()
          bad_sender = rt:perform(Op.tensor({ ch:put_op(Op, 'bad'), c:set_op(Op, 1) }))
        end, 'bad-sender')
        rt:spawn(function()
          good_sender = rt:perform(ch:put_op(Op, 'good'))
        end, 'good-sender')
        rt:spawn(function()
          receiver = rt:perform(ch:get_op(Op):and_then(function(v)
            if v == 'bad' then
              return c:set_op(Op, 2):map(function() return v end)
            end
            return Op.always(v)
          end))
        end, 'match-receiver')
      
        local status = rt:run()
        assert_eq(status.tag, 'absent', 'unmatched bad sender remains after good match commits')
        assert_eq(receiver, 'good', 'search tries another match after bad match is rejected by certification')
        assert_eq(good_sender, true, 'good sender commits')
        assert_eq(bad_sender, nil, 'bad conflicting match does not commit')
        assert_eq(c.value, 0, 'rejected bad match does not mutate resource')
        assert_eq(rt.stats.commits, 1, 'one non-conflicting match commits')
      end
      
      local function test_no_resource_mutation_without_certificate()
        local RejectingClass = Link.resource {
          name = 'world-rejecting',
          construct = function(self)
            self.label = 'world-rejecting'; self.value = 0; self.version = 0
          end,
          snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
          initial = function(_self, snap) return { base_version = snap.version, value = snap.value, written = false } end,
          claim = function(_self, _snap, fragment, _claim, ctx)
            return ctx:accept({ base_version = fragment.base_version, value = 1, written = true }, true)
          end,
          merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
          prepare = function(_self, _fragment, ctx) return ctx:conflict('prepare rejects before certificate exists') end,
        }
        local Rejecting = RejectingClass.new()
      
        local rt = Runtime.new({ quiet_deadlock = true })
        local result
        rt:spawn(function()
          result = rt:perform(Op.access(Rejecting, { tag = 'set' }))
        end, 'rejecting-resource')
        local status = rt:run()
        assert_eq(status.tag, 'absent', 'candidate rejection leads to no committable world')
        assert_eq(Rejecting.value, 0, 'resource is not mutated without a CommitCertificate')
        assert_eq(result, nil, 'participant is not resumed without a certificate')
      end
      
      local function test_cert_apply_is_no_ordinary_failure_boundary()
        local BadApplyClass = Link.resource {
          name = 'world-bad-apply',
          construct = function(self)
            self.label = 'world-bad-apply'; self.value = 0; self.version = 0
          end,
          snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
          initial = function(_self, snap) return { base_version = snap.version } end,
          claim = function(_self, _snap, fragment, _claim, ctx) return ctx:accept(fragment, true) end,
          merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
          prepare = function(self, _fragment, ctx)
            return ctx:prepared({
              resource = self,
              dirty = { self },
              consequences = { transaction = {}, resource = {}, obligation = {} },
              apply = function(_token) error('bad apply') end,
            })
          end,
        }
        local BadApply = BadApplyClass.new()
      
        local rt = Runtime.new()
        local result
        rt:spawn(function()
          result = rt:perform(Op.access(BadApply, { tag = 'go' }))
        end, 'bad-apply')
        local status = rt:run()
        assert_eq(status.tag, 'fatal', 'ordinary apply failure is fatal at certificate boundary')
        assert(tostring(status.reason):match('prepared resource commit raised'), status.reason)
        assert_eq(result, nil, 'participant is not resumed after failed apply')
      end
      
      local function test_resource_consequence_precedes_resume()
        local events = {}
        local ConsequentialClass = Link.resource {
          name = 'world-consequential',
          construct = function(self)
            self.id = 'world-consequential'; self.label = 'world-consequential'; self.value = 0; self.version = 0
          end,
          snapshot = function(self) return { resource = self, version = self.version, value = self.value } end,
          initial = function(_self, snap) return { base_version = snap.version, value = snap.value } end,
          claim = function(_self, _snap, fragment, _claim, ctx)
            return ctx:accept({ base_version = fragment.base_version, value = 1 }, true)
          end,
          merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
          prepare = function(self, fragment, ctx)
            local res = self
            return ctx:prepared({
              resource = res,
              dirty = { res },
              consequences = { transaction = {}, resource = { { kind = 'wake', key = res.id } }, obligation = {} },
              apply = function(_token) res.value = fragment.value; res.version = res.version + 1 end,
            })
          end,
        }
        local Consequential = ConsequentialClass.new()
      
        local rt
        local result
        rt = Runtime.new({ on_consequence = function(log)
          events[#events + 1] = 'publish'
          assert_eq(Consequential.value, 1, 'resource is committed before consequence observer')
          assert_eq(result, nil, 'participant has not resumed before resource consequence observer')
          assert_eq(log.resource[1].kind, 'wake', 'resource consequence is present in normalised log')
        end })
        rt:spawn(function()
          result = rt:perform(Op.access(Consequential, { tag = 'go' }))
          events[#events + 1] = 'resume'
        end, 'resource-consequence')
        assert_status(rt:run(), 'found')
        assert_eq(events[1], 'publish', 'resource consequence publishes before resume')
        assert_eq(events[2], 'resume', 'participant resumes after publish')
        assert_eq(result, true, 'participant receives result')
      end
      
      local function test_wrap_runs_after_publish()
        local events = {}
        local rt = Runtime.new({ on_consequence = function(_log)
          events[#events + 1] = 'publish'
        end })
        local result
        rt:spawn(function()
          result = rt:perform(Op.emit({ tag = 'explicit' }):and_then(function()
            return Op.always('value'):wrap(function(x)
              events[#events + 1] = 'wrap'
              return x .. '-wrapped'
            end)
          end))
        end, 'wrap-after-publish')
        assert_status(rt:run(), 'found')
        assert_eq(events[1], 'publish', 'publish precedes wrap')
        assert_eq(events[2], 'wrap', 'wrap runs during participant resumption')
        assert_eq(result, 'value-wrapped', 'wrapper result is participant-local')
      end
      
      local function test_map_over_open_bind_is_deferred()
        local rt = Runtime.new()
        local ch = Channel.new('world-map-open-bind')
        local result
        rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'map-bind-sender')
        rt:spawn(function()
          result = rt:perform(
            ch:get_op(Op)
              :and_then(function(v) return Op.always(v .. 'y') end)
              :map(function(v) return v .. 'z' end)
          )
        end, 'map-bind-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'xyz', 'map around open bind is deferred until match assignment')
      end
      
      local function test_wrap_over_open_bind_is_deferred()
        local rt = Runtime.new()
        local ch = Channel.new('world-wrap-open-bind')
        local events, result = {}, nil
        rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'wrap-bind-sender')
        rt:spawn(function()
          result = rt:perform(
            ch:get_op(Op)
              :and_then(function(v) return Op.always(v .. 'y') end)
              :wrap(function(v)
                events[#events + 1] = 'wrap:' .. v
                return v .. 'z'
              end)
          )
        end, 'wrap-bind-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(events[1], 'wrap:xy', 'wrap observes the result of the deferred bind')
        assert_eq(result, 'xyz', 'wrap around open bind runs after publication/resume')
      end
      
      local function test_bind_after_open_bind_is_deferred()
        local rt = Runtime.new()
        local ch = Channel.new('world-bind-open-bind')
        local result
        rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'bind-bind-sender')
        rt:spawn(function()
          result = rt:perform(
            ch:get_op(Op)
              :and_then(function(v) return Op.always(v .. 'y') end)
              :and_then(function(v) return Op.always(v .. 'z') end)
          )
        end, 'bind-bind-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'xyz', 'bind after open bind composes in the deferred continuation stack')
      end
      
      local function test_choice_branch_open_bind_plus_map()
        local rt = Runtime.new()
        local ch = Channel.new('world-choice-open-bind-map')
        local result
        rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'choice-bind-sender')
        rt:spawn(function()
          result = rt:perform(Op.choice(
            ch:get_op(Op)
              :and_then(function(v) return Op.always(v .. 'y') end)
              :map(function(v) return v .. 'z' end),
            Op.always('fallback')
          ))
        end, 'choice-bind-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'xyz', 'choice branch containing open bind plus map commits')
      end
      
      local function test_tensor_internal_recv_and_bind()
        local rt = Runtime.new()
        local ch = Channel.new('world-tensor-internal-bind')
        local result
        rt:spawn(function()
          result = rt:perform(Op.tensor({
            ch:put_op(Op, 'x'),
            ch:get_op(Op):and_then(function(v) return Op.always(v .. 'y') end),
          }))
        end, 'tensor-internal-bind')
        assert_status(rt:run(), 'found')
        assert_eq(result[1][1], true, 'internal send commits')
        assert_eq(result[2][1], 'xy', 'internal recv bind is continued by proof search')
      end
      
      local function test_tensor_internal_match_alternatives_search()
        local rt = Runtime.new()
        local ch = Channel.new('world-internal-match-alts')
        local c = Cell.new(0, 'world-internal-match-alts-cell')
        local result
        rt:spawn(function()
          result = rt:perform(Op.tensor({
            ch:put_op(Op, 'bad'),
            ch:put_op(Op, 'good'),
            ch:get_op(Op):and_then(function(v)
              if v == 'bad' then
                return c:set_op(Op, 1):map(function() return 'sensitive:' .. v end)
              end
              return Op.always('accepted:' .. v)
            end),
            ch:get_op(Op):and_then(function(v)
              return c:set_op(Op, 2):map(function() return 'other:' .. v end)
            end),
          }))
        end, 'tensor-internal-alts')
        assert_status(rt:run(), 'found')
        assert_eq(result[3][1], 'accepted:good', 'proof search skips the conflicting internal match pairing')
        assert_eq(result[4][1], 'other:bad', 'proof search commits the compatible internal match pairing')
        assert_eq(c.value, 2, 'only the compatible pairing mutates the cell')
      end
      
      local function test_tensor_internal_matches_appear_in_candidate_world()
        local ch = Channel.new('world-candidate-internal-match')
        local op = Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op) })
        local attempt = { id = 'stable-attempt/internal-match' }
        local view = View.open('candidate-internal-match-view')
        local candidate = Phase.with('search', function(token)
          local frontier = assert_status(Frontier.expand(op, attempt, view, token), 'found')
          return ProofSearch.find(frontier, view, token)
        end)
        local world = assert_status(candidate, 'found')
        local internal = 0
        for i = 1, #(world.matches or {}) do
          if world.matches[i].kind == 'internal' then internal = internal + 1 end
        end
        assert_eq(internal, 1, 'CandidateWorld records the tensor-internal match')
      end
      
      local function test_rejected_deferred_generated_match_does_not_repeat()
        local first = Channel.new('world-stable-first')
        local second = Channel.new('world-stable-second')
        local ops = {
          first:put_op(Op, 'go'),
          first:get_op(Op):and_then(function()
            return second:get_op(Op)
          end),
          second:put_op(Op, 'A'),
          second:put_op(Op, 'B'),
        }
        local function make_inputs()
          local inputs = {}
          return Phase.with('search', function(token)
            for i = 1, #ops do
              local view = View.open('stable-deferred-' .. tostring(i))
              local frontier = assert_status(Frontier.expand(ops[i], { id = 'stable-deferred-attempt-' .. tostring(i) }, view, token), 'found')
              inputs[#inputs + 1] = { frontier = frontier, view = view }
            end
            return inputs
          end)
        end
        local inputs1 = make_inputs()
        local first_candidate = Phase.with('search', function(token)
          return ProofSearch.find(inputs1, nil, token)
        end)
        local c1 = assert_status(first_candidate, 'found')
        local inputs2 = make_inputs()
        local second_candidate = Phase.with('search', function(token)
          return ProofSearch.find(inputs2, nil, token, { rejected = { [c1.key] = true } })
        end)
        local c2 = assert_status(second_candidate, 'found')
        assert(c1.key ~= c2.key, 'rejecting one deferred-generated match leaves a different logical match available')
        assert(not c2.key:match(c1.key, 1, true), 'rejected candidate key is not repeated')
      end
      
      local function test_candidate_key_stable_across_repeated_search()
        local ch = Channel.new('world-stable-key')
        local op = Op.tensor({ ch:put_op(Op, 'x'), ch:get_op(Op):map(function(v) return v end) })
        local attempt = { id = 'stable-key-attempt' }
        local function key_for_new_frontier()
          return Phase.with('search', function(token)
            local view = View.open('stable-key-view')
            local frontier = assert_status(Frontier.expand(op, attempt, view, token), 'found')
            local candidate = assert_status(ProofSearch.find(frontier, view, token), 'found')
            return candidate.key
          end)
        end
        local k1 = key_for_new_frontier()
        local k2 = key_for_new_frontier()
        assert_eq(k1, k2, 'candidate key names the logical world, not fresh frame/open-claim allocation')
      end
      
      return function()
        test_open_bind_after_claim_completion_continues_root()
        test_map_over_open_bind_is_deferred()
        test_wrap_over_open_bind_is_deferred()
        test_bind_after_open_bind_is_deferred()
        test_choice_branch_open_bind_plus_map()
        test_tensor_internal_recv_and_bind()
        test_tensor_internal_match_alternatives_search()
        test_tensor_internal_matches_appear_in_candidate_world()
        test_rejected_deferred_generated_match_does_not_repeat()
        test_candidate_key_stable_across_repeated_search()
        test_open_bind_can_introduce_later_claim_completion()
        test_match_alternative_rejected_candidate_does_not_reject_other_match()
        test_no_resource_mutation_without_certificate()
        test_cert_apply_is_no_ordinary_failure_boundary()
        test_resource_consequence_precedes_resume()
        test_wrap_runs_after_publish()
        print('world candidate/certificate cases: ok')
      end
    end)()
    _case()
  end
  do
    local _case = (function()
      package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
      
      local Result = require('et.kernel').Status
      local Phase = require('et.kernel').Phase
      local Op = require('et.op')
      local Runtime = require('et.runtime')
      local Channel = require('et.resources.channel')
      local Link = require('et.protocol').Link
      local Util = require('et.kernel').Util
      local View = require('et.machine.frontier').View
      local Frontier = require('et.machine.frontier').Frontier
      local ProofSearch = require('et.machine.proofnet')
      local CommitCertificate = require('et.machine.commit').Certificate
      local Consequence = require('et.machine.frontier').Consequence
      
      local function assert_eq(actual, expected, msg)
        if actual ~= expected then error((msg or 'assert_eq') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
      end
      
      local function assert_status(x, tag, msg)
        if not x or x.tag ~= tag then error((msg or 'status') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end
        return x.value
      end
      
      local next_log_id = 0
      
      local function copy_frag(f)
        local out={ base_version=f.base_version, appends={} }
        for i=1,#(f.appends or {}) do out.appends[i]=f.appends[i] end
        return out
      end
      
      local function fragment_projection(snap, base, full, ctx)
        if base.base_version ~= snap.version or full.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
        local out={ base_version=snap.version, appends={} }
        for i=#base.appends+1,#full.appends do out.appends[#out.appends+1]=full.appends[i] end
        if #out.appends == 0 then return nil end
        return out
      end
      
      local function fragment_extend(snap, prefix, delta, ctx)
        if prefix.base_version ~= snap.version or delta.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
        local out=copy_frag(prefix)
        for i=1,#delta.appends do out.appends[#out.appends+1]=delta.appends[i] end
        return out
      end
      
      local function fragment_coexist(snap, left, right, ctx)
        if left == nil then return copy_frag(right) end
        if right == nil then return copy_frag(left) end
        if left.base_version ~= snap.version or right.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
        local out=copy_frag(left)
        for i=1,#right.appends do out.appends[#out.appends+1]=right.appends[i] end
        return out
      end
      
      local Log = Link.resource {
        name = 'test-log',
        construct = function(self, label)
          next_log_id = next_log_id + 1
          self.id='log-'..next_log_id
          self.label=label or ('log-'..next_log_id)
          self.version=0
          self.records={}
        end,
        snapshot = function(self) return { resource=self, version=self.version, count=#self.records } end,
        initial = function(_self, snap) return { base_version=snap.version, appends={} } end,
        claim = function(_self, snap, fragment, claim, ctx)
          if fragment.base_version ~= snap.version then return ctx:stale({snap.resource}, 'log fragment stale') end
          local req = claim.request or claim.payload or claim
          if req.tag ~= 'append' then return ctx:fatal('unknown log request '..tostring(req.tag)) end
          local out=copy_frag(fragment)
          out.appends[#out.appends+1]=req.value
          return ctx:accept(out, true)
        end,
        merge = function(_self, snap, request, ctx)
          local kind = request.kind or 'coexist'
          local base = request.base
          local fragments = request.fragments or {}
          if kind == 'project' then
            return fragment_projection(snap, base, fragments[1], ctx)
          elseif kind == 'extend' then
            local acc = base
            for i=1,#fragments do
              local r = fragment_extend(snap, acc, fragments[i], ctx)
              if r and r.tag then return r end
              acc = r
            end
            return acc
          end
          local acc = nil
          for i=1,#fragments do
            acc = fragment_coexist(snap, acc, fragments[i], ctx)
            if acc and acc.tag then return acc end
          end
          return acc
        end,
        prepare = function(self, fragment, ctx)
          if fragment.base_version ~= self.version then return ctx:stale({self}, 'log fragment stale') end
          local log=self; local appends={}
          for i=1,#fragment.appends do appends[i]=fragment.appends[i] end
          return ctx:prepared({
            resource=log, fragment=fragment, dirty=#appends>0 and {log} or {}, consequences={transaction={},resource={},obligation={}},
            apply=function(commit_token)
              Phase.require(commit_token,'commit')
              for i=1,#appends do log.records[#log.records+1]=appends[i] end
              if #appends>0 then log.version=log.version+1 end
            end,
          })
        end,
      }
      function Log:append_op(value) return Op.access(self, { tag='append', value=value }) end
      
      local function test_product_base_delta_law()
        local log=Log.new('product-base')
        local rt=Runtime.new()
        rt:spawn(function()
          rt:perform(log:append_op('base'):and_then(function()
            return Op.tensor({ log:append_op('lane'), Op.always('ok') })
          end))
        end, 'product-base')
        assert_status(rt:run(), 'found')
        assert_eq(#log.records, 2, 'product base is committed once')
        assert_eq(log.records[1], 'base')
        assert_eq(log.records[2], 'lane')
      end
      
      local function test_box_path_and_occurrence_lane_path_are_canonical()
        local ch=Channel.new('paths')
        local op=Op.tensor({ Op.all({ ch:put_op(Op,'x') }), Op.all({ ch:get_op(Op) }) })
        local view=View.open('paths-view')
        local frontier=assert_status(Frontier.expand_in_search(op,{id='paths-attempt'},view),'found')
        local frame=frontier.frames[1]
        assert_eq(#frame.open_claims,2)
        for i=1,#frame.open_claims do
          local p=frame.open_claims[i]
          assert_eq(#p.box_path, #p.origin.lane_path, 'open-claim box path and occurrence lane path length agree')
          for j=1,#p.box_path do
            assert_eq(p.box_path[j].box, p.origin.lane_path[j].box, 'box id order agrees')
            assert_eq(p.box_path[j].lane, p.origin.lane_path[j].lane, 'lane order agrees')
          end
          assert_eq(p.box_path[1].kind, 'tensor', 'outermost box is first')
          assert_eq(p.box_path[2].kind, 'all', 'innermost box is second')
        end
      end
      
      local function test_candidate_has_selected_operation_occurrences()
        local ch=Channel.new('selected-ops')
        local op=Op.tensor({ ch:put_op(Op,'x'), ch:get_op(Op), Op.emit({tag='publish', key='e1'}) })
        local view=View.open('selected-view')
        local frontier=assert_status(Frontier.expand_in_search(op,{id='selected-attempt'},view),'found')
        local cand=assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
        local kinds={}
        for i=1,#cand.selected_occurrences do kinds[cand.selected_occurrences[i].kind]=true end
        assert(kinds.open_claim, 'selected open-claim occurrence present')
        assert(kinds.emit, 'selected emit occurrence present')
        assert(kinds.match, 'selected match occurrence present')
      end
      
      
      local function test_commit_certificate_consumes_candidate_selected_delta()
        local events={}
        local op=Op.emit({tag='selected-delta-event'}):and_then(function() return Op.always('ok') end)
        local view=View.open('selected-delta-view')
        local frontier=assert_status(Frontier.expand_in_search(op,{id='selected-delta-attempt'},view),'found')
        local cand=assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
        assert(cand.selected_delta and cand.selected_delta.consequences, 'candidate exposes selected_delta')
        -- Scrub root-local evidence to prove certification consumes CandidateWorld.selected_delta,
        -- not recollected per-root evidence.
        for i=1,#cand.roots do cand.roots[i].evidence.consequences = Consequence.empty() end
        local cert=assert_status(CommitCertificate.try_build(cand),'found')
        for i=1,#cert.consequences.transaction do events[#events+1]=cert.consequences.transaction[i].tag end
        assert_eq(events[1], 'selected-delta-event', 'certificate consumes selected_delta consequences')
      end
      
      local function test_absence_certificate_is_explicit()
        local op=Op.never():or_else(Op.always('fallback'))
        local view=View.open('absence-cert-view')
        local frontier=assert_status(Frontier.expand_in_search(op,{id='absence-cert-attempt'},view),'found')
        local cand=assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
        local cert=assert_status(CommitCertificate.try_build(cand),'found')
        assert_eq(#cert.absence_certificates, 1, 'fallback carries an absence certificate')
        assert_eq(cert.absence_certificates[1].tag, 'absence_certificate')
        assert(cert.absence_certificates[1].obligation_id, 'absence certificate names obligation')
      end
      
      local function test_no_observation_compatibility_module()
        package.loaded['et.observation']=nil
        local ok = pcall(require, 'et.observation')
        assert_eq(ok, false, 'Observation compatibility module has been removed')
      end
      
      return function()
        test_product_base_delta_law()
        test_box_path_and_occurrence_lane_path_are_canonical()
        test_candidate_has_selected_operation_occurrences()
        test_commit_certificate_consumes_candidate_selected_delta()
        test_absence_certificate_is_explicit()
        test_no_observation_compatibility_module()
        print('world boundary cases: ok')
      end
    end)()
    _case()
  end
  do
    local _case = (function()
      package.path = table.concat({ './?.lua', './?/init.lua', './?/?.lua', package.path }, ';')
      
      local Result = require('et.kernel').Status
      local Phase = require('et.kernel').Phase
      local Op = require('et.op')
      local Runtime = require('et.runtime')
      local Channel = require('et.resources.channel')
      local Cell = require('et.resources.cell')
      local Obligation = require('et.machine.frontier').Obligation
      local View = require('et.machine.frontier').View
      local Frontier = require('et.machine.frontier').Frontier
      local ProofSearch = require('et.machine.proofnet')
      local CommitCertificate = require('et.machine.commit').Certificate
      local Util = require('et.kernel').Util
      local Link = require('et.protocol').Link
      
      local function assert_eq(actual, expected, msg)
        if actual ~= expected then error((msg or 'assert_eq') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
      end
      
      local function assert_status(x, tag, msg)
        if not x or x.tag ~= tag then error((msg or 'status') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2) end
        return x.value
      end
      
      local function reset()
        if Obligation.reset_for_tests then Obligation.reset_for_tests() end
      end
      
      
      local BadResource = Link.resource {
        name = 'bad-obligation',
        construct = function(self)
          self.id = 'bad-obligation'
          self.version = 0
        end,
        snapshot = function(self) return { resource = self, version = self.version } end,
        initial = function(_self, snap) return { base_version = snap.version, touched = false } end,
        claim = function(_self, _snap, fragment, _claim, ctx)
          return ctx:accept({ base_version = fragment.base_version, touched = true }, 'bad')
        end,
        merge = function(_self, _snap, request, _ctx)
          local fragments = request.fragments or {}
          if request.kind == 'project' then
            local base, full = request.base, fragments[1]
            if base.touched == full.touched then return nil end
            return full
          end
          return fragments[#fragments] or request.base
        end,
        prepare = function(self, _fragment, ctx) return ctx:conflict('bad resource rejects candidate', self) end,
      }
      function BadResource:op() return Op.access(self, { tag = 'bad' }) end
      

      local function test_generic_with_obligation_selects_linear_obligation()
        reset()
        local rt = Runtime.new()
        local ref_holder
        local got
        rt:spawn(function()
          got = rt:perform(Op.with_obligation('admission', { task = 't1' }, function(ref)
            ref_holder = ref
            return Op.always('admitted', ref.kind)
          end))
        end, 'generic-obligation')
        assert_status(rt:run(), 'found')
        assert_eq(got, 'admitted')
        assert(ref_holder, 'generic obligation callback receives ref')
        assert_eq(ref_holder.kind, 'admission', 'generic obligation kind is preserved')
        assert_eq(Obligation.state(ref_holder), 'selected', 'selected generic obligation becomes terminal')
      end
      
      local function test_with_nack_does_not_run_callback_at_construction()
        reset()
        local ran = 0
        local op = Op.with_nack(function(_)
          ran = ran + 1
          return Op.always('ok')
        end)
        assert_eq(ran, 0, 'with_nack callback is not construction-time')
        local rt = Runtime.new()
        local got
        rt:spawn(function() got = rt:perform(op) end, 'construction')
        assert_status(rt:run(), 'found')
        assert_eq(ran, 1, 'with_nack callback runs during expansion')
        assert_eq(got, 'ok')
      end
      
      local function test_selected_with_nack_commits_selected_obligation_before_publish_resume()
        reset()
        local seen = {}
        local rt = Runtime.new({
          on_consequence = function(log)
            seen[#seen + 1] = { phase = 'consequence', log = log }
          end,
        })
        local observed_state_at_resume
        local ref_id
        rt:spawn(function()
          local op = Op.with_nack(function(nack)
            -- The nack is not used; the protected occurrence is selected.
            return Op.always('protected'):map(function(v)
              return v, nack.obligation.id
            end)
          end)
          local v, id = rt:perform(op)
          ref_id = id
          observed_state_at_resume = Obligation.state({ __et_obligation = true, id = id })
          return v
        end, 'selected')
        assert_status(rt:run(), 'found')
        assert_eq(observed_state_at_resume, 'selected', 'selected obligation state visible before participant continuation completes')
        assert_eq(#seen, 1, 'consequence callback ran once')
        assert_eq(#seen[1].log.obligation, 1, 'selected obligation consequence was published')
        assert_eq(seen[1].log.obligation[1].kind, 'selected')
        assert_eq(seen[1].log.obligation[1].id, ref_id)
      end
      
      local function test_published_unselected_with_nack_becomes_lost_when_attempt_resolves_elsewhere()
        reset()
        local rt = Runtime.new()
        local selected_ref_id
        local lost_ref_id
        local got
        local bad = BadResource.new()
        local op = Op.choice(
          Op.with_nack(function(nack)
            lost_ref_id = nack.obligation.id
            return bad:op()
          end),
          Op.with_nack(function(nack)
            selected_ref_id = nack.obligation.id
            return Op.always('winner')
          end)
        )
        rt:spawn(function() got = rt:perform(op) end, 'lost')
        assert_status(rt:run(), 'found')
        assert_eq(got, 'winner')
        assert_eq(Obligation.state({ __et_obligation = true, id = selected_ref_id }), 'selected', 'winner obligation selected')
        assert_eq(Obligation.state({ __et_obligation = true, id = lost_ref_id }), 'lost', 'published unselected obligation lost')
      end
      
      local function test_nack_observes_prior_lost_only()
        reset()
        local ref_holder
        local bad = BadResource.new()
        local op = Op.choice(
          Op.with_nack(function(nack)
            ref_holder = nack.obligation
            return bad:op()
          end),
          Op.always('resolve')
        )
        local rt1 = Runtime.new()
        local got1
        rt1:spawn(function() got1 = rt1:perform(op) end, 'make-lost')
        assert_status(rt1:run(), 'found')
        assert_eq(got1, 'resolve')
        assert_eq(Obligation.state(ref_holder), 'lost')
      
        local rt2 = Runtime.new()
        local got2
        rt2:spawn(function() got2 = rt2:perform(Op._nack(ref_holder)) end, 'observe-lost')
        assert_status(rt2:run(), 'found')
        assert_eq(got2, true, 'nack closes once settlement is prior-lost')
      end
      
      local function test_nack_does_not_close_in_same_commit_that_would_make_occurrence_lost()
        reset()
        local got
        local rt = Runtime.new({ quiet_deadlock = true })
        local op = Op.with_nack(function(nack)
          return Op.never():or_else(nack)
        end)
        rt:spawn(function() got = rt:perform(op) end, 'same-plan')
        local r = rt:run()
        assert(r.tag == 'absent' or r.tag == 'conflict' or r.tag == 'reject_candidate', 'same-plan nack must not commit; got '..tostring(r.tag))
        assert_eq(got, nil)
      end
      
      
      local function test_withdrawn_attempt_enables_nack_later()
        reset()
        local rt1 = Runtime.new({ quiet_deadlock = true })
        local ref_holder
        local task = rt1:spawn(function()
          return rt1:perform(Op.with_nack(function(nack)
            ref_holder = nack.obligation
            return Op.always('would-commit')
          end))
        end, 'withdraw-source')
        rt1:run_one_runnable()
        assert_eq(task.state, 'waiting', 'task parked before withdrawal')
        assert_status(rt1:withdraw(task), 'found')
        assert_eq(Obligation.state(ref_holder), 'withdrawn', 'published pending ref becomes withdrawn')
      
        local rt2 = Runtime.new()
        local got
        rt2:spawn(function() got = rt2:perform(Op._nack(ref_holder)) end, 'observe-withdrawn')
        assert_status(rt2:run(), 'found')
        assert_eq(got, true, 'nack closes once settlement is prior-withdrawn')
      end
      
      
      local function test_refresh_does_not_orphan_published_obligations()
        reset()
        local rt = Runtime.new()
        local ch = Channel.new('refresh-orphan')
        local cell = Cell.new(0, 'refresh-orphan-cell')
        local ref_holder
        local got_a, got_b
      
        local protected = cell:get_op(Op):and_then(function(v)
          if v == 0 then
            return Op.with_nack(function(nack)
              ref_holder = nack.obligation
              return ch:get_op(Op)
            end)
          end
          return Op.always('after')
        end)
      
        rt:spawn(function() got_a = rt:perform(protected) end, 'refresh-obligation-root')
        rt:spawn(function() got_b = rt:perform(cell:set_op(Op, 1):and_then(function() return Op.always('set') end)) end, 'refresh-trigger')
      
        assert_status(rt:run(), 'found')
        assert_eq(got_b, 'set')
        assert_eq(got_a, 'after')
        assert(rt.stats.refreshes >= 1, 'first attempt should refresh after cell change')
        assert(ref_holder, 'initial with_nack publication should have happened')
        assert_eq(Obligation.state(ref_holder), 'lost', 'published obligation from earlier frontier is lost when the same attempt resolves unselected')
      end
      
      local function test_with_nack_preserves_product_lane_identity()
        reset()
        local ch = Channel.new('nack-lanes')
        local view = View.open('nack-lanes-view')
        local op = Op.tensor({
          Op.with_nack(function(_) return ch:put_op(Op, 'x') end),
          ch:get_op(Op),
        })
        local frontier = assert_status(Frontier.expand_in_search(op, { id = 'nack-lanes-attempt' }, view), 'found')
        local cand = assert_status(Phase.with('search', function(token) return ProofSearch.find(frontier, view, token) end), 'found')
        local found_selected_obligation = false
        for i = 1, #(cand.selected_delta.selected_obligations or {}) do
          local ref = cand.selected_delta.selected_obligations[i]
          if ref.origin and #(ref.origin.lane_path or {}) > 0 then found_selected_obligation = true end
        end
        assert(found_selected_obligation, 'selected obligation keeps product lane identity')
        local cert = assert_status(CommitCertificate.try_build(cand), 'found')
        assert_eq(#cert.consequences.obligation, 1, 'selected obligation consequence present')
      end
      
      return function()
        test_generic_with_obligation_selects_linear_obligation()
        test_with_nack_does_not_run_callback_at_construction()
        test_selected_with_nack_commits_selected_obligation_before_publish_resume()
        test_published_unselected_with_nack_becomes_lost_when_attempt_resolves_elsewhere()
        test_nack_observes_prior_lost_only()
        test_nack_does_not_close_in_same_commit_that_would_make_occurrence_lost()
        test_withdrawn_attempt_enables_nack_later()
        test_refresh_does_not_orphan_published_obligations()
        test_with_nack_preserves_product_lane_identity()
        print('world linear-obligation cases: ok')
      end
    end)()
    _case()
  end
  print('machine/world tests: ok')
end
