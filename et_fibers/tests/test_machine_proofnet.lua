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
      local View = require('et.machine.frontier').View
      local Frontier = require('et.machine.frontier').Frontier
      local ProofSearch = require('et.machine.proofnet')
      local CommitCertificate = require('et.machine.commit').Certificate
      local Phase = require('et.kernel').Phase
      local Link = require('et.protocol').Link
      local Consequence = require('et.machine.frontier').Consequence
      
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
      
      local function test_simple_send_receive()
        local rt = Runtime.new()
        local ch = Channel.new('simple')
        local sent, received
        rt:spawn(function() sent = rt:perform(ch:put_op(Op, 'hello')) end, 'sender')
        rt:spawn(function() received = rt:perform(ch:get_op(Op)) end, 'receiver')
        assert_status(rt:run(), 'found')
        assert_eq(sent, true, 'send returns committed unit')
        assert_eq(received, 'hello', 'receive gets sent value')
        assert_eq(rt.stats.commits, 1, 'send/receive are one commit')
      end
      
      local function test_choice_discards_losing_branch()
        local events = {}
        local rt = Runtime.new({ on_consequence = function(log)
          for i = 1, #log.transaction do events[#events + 1] = log.transaction[i].tag end
        end })
        local ch = Channel.new('choice')
        local received
        rt:spawn(function()
          received = rt:perform(
            Op.choice(
              Op.emit({ tag = 'left-winner' }):and_then(function() return ch:get_op(Op) end),
              Op.emit({ tag = 'right-loser' }):and_then(function() return ch:get_op(Op) end)
            )
          )
        end, 'chooser')
        rt:spawn(function() rt:perform(ch:put_op(Op, 'x')) end, 'sender')
        assert_status(rt:run(), 'found')
        assert_eq(received, 'x')
        assert_eq(#events, 1, 'only selected branch emits')
        assert_eq(events[1], 'left-winner', 'chosen branch consequence is published')
      end
      
      local function test_tensor_permits_internal_match()
        local rt = Runtime.new()
        local ch = Channel.new('tensor-internal')
        local result
        rt:spawn(function()
          result = rt:perform(Op.tensor({ ch:put_op(Op, 42), ch:get_op(Op) }))
        end, 'tensor')
        assert_status(rt:run(), 'found')
        assert_eq(result[1][1], true, 'internal send commits')
        assert_eq(result[2][1], 42, 'internal receive obtains value')
        assert_eq(rt.stats.commits, 1)
      end
      
      local function test_all_forbids_internal_match()
        local rt = Runtime.new({ quiet_deadlock = true })
        local ch = Channel.new('all-no-internal')
        rt:spawn(function()
          rt:perform(Op.all({ ch:put_op(Op, 42), ch:get_op(Op) }))
        end, 'all')
        local result = rt:run()
        assert_eq(result.tag, 'absent', 'all cannot use an internal match')
      end
      
      local function test_triple_swap()
        local rt = Runtime.new()
        local ab = Channel.new('ab')
        local bc = Channel.new('bc')
        local ca = Channel.new('ca')
        local a, b, c
        rt:spawn(function()
          a = rt:perform(Op.tensor({ ab:put_op(Op, 'A'), ca:get_op(Op) }))
        end, 'A')
        rt:spawn(function()
          b = rt:perform(Op.tensor({ bc:put_op(Op, 'B'), ab:get_op(Op) }))
        end, 'B')
        rt:spawn(function()
          c = rt:perform(Op.tensor({ ca:put_op(Op, 'C'), bc:get_op(Op) }))
        end, 'C')
        assert_status(rt:run(), 'found')
        assert_eq(a[2][1], 'C')
        assert_eq(b[2][1], 'A')
        assert_eq(c[2][1], 'B')
        assert_eq(rt.stats.commits, 1, 'triple swap is one commit')
      end
      
      
      local function test_wrap_is_root_local_and_exematched()
        local rt = Runtime.new()
        local ch = Channel.new('wrap-root-local')
        local sender, receiver, ran_sender, ran_receiver
        rt:spawn(function()
          sender = rt:perform(ch:put_op(Op, 'payload'):wrap(function(x)
            ran_sender = true
            return x and 'sender-wrapped' or 'sender-not-wrapped'
          end))
        end, 'wrap-sender')
        rt:spawn(function()
          receiver = rt:perform(ch:get_op(Op):wrap(function(x)
            ran_receiver = true
            return x .. '-wrapped'
          end))
        end, 'wrap-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(ran_sender, true, 'sender wrapper runs')
        assert_eq(ran_receiver, true, 'receiver wrapper runs')
        assert_eq(sender, 'sender-wrapped', 'sender wrapper transforms only sender result')
        assert_eq(receiver, 'payload-wrapped', 'receiver wrapper transforms only receiver result')
      end
      
      local function test_choice_conflict_is_branch_local()
        local rt = Runtime.new()
        local c = Cell.new(0, 'choice-conflict-cell')
        local result
        rt:spawn(function()
          result = rt:perform(Op.choice(
            Op.tensor({ c:set_op(Op, 1), c:set_op(Op, 2) }),
            Op.always('ok')
          ))
        end, 'choice-conflict')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'ok', 'conflicting unselected choice branch is discarded')
        assert_eq(c.value, 0, 'discarded conflicting branch does not mutate resource')
      end
      
      local function test_claim_completion_and_resource_fragments_certify_together()
        local rt = Runtime.new()
        local ch = Channel.new('resource-claim_completion')
        local c = Cell.new(0, 'resource-claim_completion-cell')
        local left, right
        rt:spawn(function()
          left = rt:perform(Op.tensor({ c:set_op(Op, 1), ch:put_op(Op, 'x') }))
        end, 'resource-sender')
        rt:spawn(function()
          right = rt:perform(Op.tensor({ c:get_op(Op), ch:get_op(Op) }))
        end, 'resource-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(left[1][1], true, 'set result is returned')
        assert_eq(left[2][1], true, 'send result is returned')
        assert_eq(right[1][1], 0, 'resource get returns the raw proof-time fragment value')
        assert_eq(right[2][1], 'x', 'claim_completion value is received')
        assert_eq(c.value, 1, 'resource fragment merged during certification commits')
        assert_eq(rt.stats.commits, 1, 'claim_completion and resource update commit together')
      end
      
      local function test_or_else_channel_absence_certified()
        local rt = Runtime.new()
        local ch = Channel.new('or-channel')
        local result
        rt:spawn(function()
          result = rt:perform(ch:get_op(Op):or_else(Op.always('fallback')))
        end, 'fallback-channel')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'fallback')
      end
      
      local function test_or_else_channel_primary_blocks_fallback()
        local rt = Runtime.new()
        local ch = Channel.new('or-channel-primary')
        local result
        rt:spawn(function()
          result = rt:perform(ch:get_op(Op):or_else(Op.always('fallback')))
        end, 'receiver')
        rt:spawn(function() rt:perform(ch:put_op(Op, 'primary')) end, 'sender')
        assert_status(rt:run(), 'found')
        assert_eq(result, 'primary')
      end
      
      
      local function test_candidate_local_conflict_rejects_and_search_continues()
        local rt = Runtime.new({ quiet_deadlock = true })
        local ch = Channel.new('candidate-local-reject')
        local c = Cell.new(0, 'candidate-local-reject-cell')
        local sender, receiver
        rt:spawn(function()
          sender = rt:perform(Op.choice(
            Op.tensor({ ch:put_op(Op, 'bad'), c:set_op(Op, 1) }),
            ch:put_op(Op, 'good')
          ))
        end, 'candidate-local-a')
        rt:spawn(function()
          receiver = rt:perform(Op.tensor({ ch:get_op(Op), c:set_op(Op, 2) }))
        end, 'candidate-local-b')
        assert_status(rt:run(), 'found')
        assert_eq(sender, true, 'compatible alternative send branch commits')
        assert_eq(receiver[1][1], 'good', 'receiver observes the non-conflicting branch payload')
        assert_eq(receiver[2][1], true, 'receiver resource write commits')
        assert_eq(c.value, 2, 'candidate-local resource conflict was rejected, not fatal')
      end
      
      local function test_product_skips_conflicting_combinations()
        local rt = Runtime.new({ quiet_deadlock = true })
        local c = Cell.new(0, 'product-local-conflict-cell')
        local result
        rt:spawn(function()
          result = rt:perform(Op.tensor({
            Op.choice(c:set_op(Op, 1), c:set_op(Op, 2)),
            Op.choice(c:set_op(Op, 3), Op.always('ok')),
          }))
        end, 'product-local-conflict')
        assert_status(rt:run(), 'found')
        assert_eq(result[1][1], true, 'valid product combination keeps first cell write')
        assert_eq(result[2][1], 'ok', 'conflicting product alternatives are skipped')
        assert_eq(c.value, 1, 'valid product combination commits')
      end
      
      local function test_channel_nil_payload_is_delivered()
        local rt = Runtime.new()
        local ch = Channel.new('nil-payload')
        local sent, received = 'unset', 'unset'
        local received_ran = false
        rt:spawn(function() sent = rt:perform(ch:put_op(Op, nil)) end, 'nil-sender')
        rt:spawn(function()
          received = rt:perform(ch:get_op(Op))
          received_ran = true
        end, 'nil-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(sent, true, 'nil send commits')
        assert_eq(received, nil, 'nil payload is preserved by claim_completion assignment')
        assert_eq(received_ran, true, 'receiver resumed after nil payload')
      end
      
      
      local function test_or_else_absence_uses_certifiable_primary_worlds()
        local rt = Runtime.new({ quiet_deadlock = true })
        local ch = Channel.new('certifiable-absence')
        local c = Cell.new(0, 'certifiable-absence-cell')
        local receiver, sender
        rt:spawn(function()
          receiver = rt:perform(
            Op.tensor({ ch:get_op(Op), c:set_op(Op, 1) })
              :or_else(Op.always('fallback'))
          )
        end, 'certifiable-absence-receiver')
        rt:spawn(function()
          sender = rt:perform(Op.tensor({ ch:put_op(Op, 'x'), c:set_op(Op, 2) }))
        end, 'certifiable-absence-sender')
        local status = rt:run()
        assert_eq(status.tag, 'absent', 'sender remains waiting after fallback commits')
        assert_eq(receiver, 'fallback', 'fallback commits when every primary proof-net world fails certification')
        assert_eq(sender, nil, 'conflicting sender transaction does not commit')
        assert_eq(c.value, 0, 'uncertifiable primary does not mutate cell')
        assert_eq(rt.stats.commits, 1, 'only fallback commit is applied')
      end
      
      local function test_wrap_error_is_root_local_after_commit()
        local rt = Runtime.new()
        local ch = Channel.new('wrap-error-local')
        local sender, receiver
        local sender_task = rt:spawn(function()
          sender = rt:perform(ch:put_op(Op, 'payload'):wrap(function()
            error('wrap boom')
          end))
        end, 'wrap-error-sender')
        local receiver_task = rt:spawn(function()
          receiver = rt:perform(ch:get_op(Op))
        end, 'wrap-error-receiver')
        assert_status(rt:run(), 'found')
        assert_eq(sender, nil, 'failing sender wrapper does not return normally')
        assert_eq(receiver, 'payload', 'peer root still resumes after committed claim_completion')
        assert_eq(sender_task.state, 'failed', 'failing wrapper is recorded on the participant task')
        assert(tostring(sender_task.error):match('wrap boom'), sender_task.error)
        assert_eq(receiver_task.state, 'done', 'peer participant completes')
        assert_eq(#rt.waiting, 0, 'committed roots are detached from waiting set')
      end
      
      local function test_commit_certificate_is_one_shot()
        local c = Cell.new(0, 'one-shot-cert-cell')
        local view = View.open('one-shot-cert-view')
        local attempt = { id = 'one-shot-attempt', task = { label = 'one-shot-task' } }
        local frontier = assert_status(Phase.with('search', function(token)
          return Frontier.expand(c:set_op(Op, 1), attempt, view, token)
        end), 'found')
        local candidate = assert_status(Phase.with('search', function(token)
          return ProofSearch.find({ { frontier = frontier, view = view, task = attempt.task } }, nil, token)
        end), 'found')
        local cert = assert_status(CommitCertificate.try_build(candidate), 'found')
        assert_status(cert:apply(), 'found')
        assert_eq(c.value, 1, 'first apply mutates resource')
        assert_eq(c.version, 1, 'first apply advances version once')
        assert_eq(cert:apply().tag, 'fatal', 'second apply is rejected')
        assert_eq(c.value, 1, 'second apply does not mutate value')
        assert_eq(c.version, 1, 'second apply does not advance version')
      end
      
      local function test_consequence_observer_error_does_not_strand_roots()
        local rt = Runtime.new({ on_consequence = function(_) error('observer failure') end })
        local c = Cell.new(0, 'consequence-observer-cell')
        local result
        rt:spawn(function() result = rt:perform(c:set_op(Op, 1)) end, 'consequence-observer')
        assert_status(rt:run(), 'found')
        assert_eq(result, true, 'root resumes despite observer error')
        assert_eq(c.value, 1, 'commit is applied despite observer error')
        assert_eq(rt.consequence_errors and #rt.consequence_errors or 0, 1, 'observer error is recorded')
      end
      
      
      local function test_commit_apply_failure_poisons_certificate()
        local BadClass = Link.resource {
          name = 'bad-apply',
          construct = function(self)
            self.label = 'bad-apply'
            self.version = 0
            self.apply_count = 0
          end,
          snapshot = function(self) return { resource = self, version = self.version } end,
          initial = function(_self, snap) return { base_version = snap.version } end,
          claim = function(_self, _snap, fragment, _claim, ctx) return ctx:accept(fragment, true) end,
          merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
          prepare = function(self, _fragment, ctx)
            local resource = self
            return ctx:prepared({
              resource = resource,
              dirty = { resource },
              consequences = Consequence.empty(),
              resolve = function(_) return Result.conflict('bad resource has no observations') end,
              apply = function(_commit_token)
                resource.apply_count = resource.apply_count + 1
                error('apply boom')
              end,
            })
          end,
        }
        local Bad = BadClass.new()
      
        local view = View.open('bad-apply-view')
        local attempt = { id = 'bad-apply-attempt', task = { label = 'bad-apply-task' } }
        local frontier = assert_status(Phase.with('search', function(token)
          return Frontier.expand(Op.access(Bad, { tag = 'go' }), attempt, view, token)
        end), 'found')
        local candidate = assert_status(Phase.with('search', function(token)
          return ProofSearch.find({ { frontier = frontier, view = view, task = attempt.task } }, nil, token)
        end), 'found')
        local cert = assert_status(CommitCertificate.try_build(candidate), 'found')
        local applied = cert:apply()
        assert_eq(applied.tag, 'fatal', 'apply errors become fatal')
        assert(tostring(applied.reason):match('prepared resource commit raised'), applied.reason)
        assert_eq(cert.state, 'poisoned', 'failed apply poisons the certificate')
        assert_eq(Bad.apply_count, 1, 'prepared apply was attempted exactly once')
        assert_eq(cert:apply().tag, 'fatal', 'poisoned certificate cannot be re-applied')
      end
      
      local function test_runtime_does_not_resume_after_apply_failure()
        local BadClass = Link.resource {
          name = 'bad-runtime-apply',
          construct = function(self)
            self.label = 'bad-runtime-apply'
            self.version = 0
          end,
          snapshot = function(self) return { resource = self, version = self.version } end,
          initial = function(_self, snap) return { base_version = snap.version } end,
          claim = function(_self, _snap, fragment, _claim, ctx) return ctx:accept(fragment, true) end,
          merge = function(_self, _snap, request, _ctx) return (request.fragments or {})[1] or request.base end,
          prepare = function(self, _fragment, ctx)
            return ctx:prepared({
              resource = self,
              dirty = { self },
              consequences = Consequence.empty(),
              apply = function(_commit_token) error('runtime apply boom') end,
            })
          end,
        }
        local Bad = BadClass.new()
      
        local rt = Runtime.new()
        local result
        local task = rt:spawn(function()
          result = rt:perform(Op.access(Bad, { tag = 'go' }))
        end, 'bad-runtime-apply')
        local status = rt:run()
        assert_eq(status.tag, 'fatal', 'runtime returns fatal after prepared apply failure')
        assert_eq(result, nil, 'root is not resumed unless certificate reaches applied')
        assert_eq(task.state, 'waiting', 'failed commit leaves participant unresumed')
      end
      
      local function test_consequence_normalisation_typed_logs()
        local log = Consequence.empty()
        log.resource = {
          { kind = 'wake', key = 'waiter-1' },
          { kind = 'wake', key = 'waiter-1' },
          { kind = 'kick', id = 'worker-1' },
          { kind = 'publish', topic = 'events', value = 1 },
        }
        local normalised = assert_status(Consequence.normalise(log), 'found')
        assert_eq(#normalised.resource, 3, 'duplicate idempotent resource consequence is collapsed')
        assert_eq(normalised.resource[1].kind, 'wake')
        assert_eq(normalised.resource[2].kind, 'kick')
        assert_eq(normalised.resource[3].kind, 'publish')
      
        local duplicate_obligation = Consequence.empty()
        duplicate_obligation.obligation = {
          { kind = 'settlement', id = 'ob-1' },
          { kind = 'settlement', id = 'ob-1' },
        }
        assert_eq(Consequence.normalise(duplicate_obligation).tag, 'conflict', 'duplicate one-shot obligation conflicts')
      
        local unknown_resource = Consequence.empty()
        unknown_resource.resource = { { kind = 'mystery', key = 'x' } }
        assert_eq(Consequence.normalise(unknown_resource).tag, 'conflict', 'unknown resource consequence kind conflicts')
      
        local unknown_obligation = Consequence.empty()
        unknown_obligation.obligation = { { kind = 'mystery', id = 'x' } }
        assert_eq(Consequence.normalise(unknown_obligation).tag, 'conflict', 'unknown obligation consequence kind conflicts')
      end
      
      local function test_mandatory_consequence_interpreter_precedes_observer_and_resume()
        local events = {}
        local c = Cell.new(0, 'mandatory-before-observer')
        local result
        local rt
        rt = Runtime.new({ on_consequence = function(log)
          events[#events + 1] = 'observer'
          assert_eq(c.value, 1, 'resource state is committed before consequence observer')
          assert_eq(result, nil, 'participant has not resumed before observer')
          assert_eq(#(rt.published_consequences or {}), 1, 'mandatory interpreter ran before observer')
          assert_eq(log.transaction[1].tag, 'txn', 'observer receives normalised transaction log')
        end })
        rt:spawn(function()
          result = rt:perform(
            Op.emit({ tag = 'txn' }):and_then(function()
              return c:set_op(Op, 1):wrap(function(x)
                events[#events + 1] = 'wrap'
                return x
              end)
            end)
          )
        end, 'mandatory-order')
        assert_status(rt:run(), 'found')
        assert_eq(result, true, 'participant resumes after mandatory publish and observer')
        assert_eq(events[1], 'observer', 'observer runs before participant post wrapper')
        assert_eq(events[2], 'wrap', 'post wrapper runs during participant resumption')
        assert_eq(#rt.published_consequences, 1, 'mandatory publication recorded exactly once')
      end
      
      return function()
        test_simple_send_receive()
        test_choice_discards_losing_branch()
        test_tensor_permits_internal_match()
        test_all_forbids_internal_match()
        test_triple_swap()
        test_wrap_is_root_local_and_exematched()
        test_choice_conflict_is_branch_local()
        test_claim_completion_and_resource_fragments_certify_together()
        test_or_else_channel_absence_certified()
        test_or_else_channel_primary_blocks_fallback()
        test_candidate_local_conflict_rejects_and_search_continues()
        test_product_skips_conflicting_combinations()
        test_channel_nil_payload_is_delivered()
        test_or_else_absence_uses_certifiable_primary_worlds()
        test_wrap_error_is_root_local_after_commit()
        test_commit_certificate_is_one_shot()
        test_commit_apply_failure_poisons_certificate()
        test_runtime_does_not_resume_after_apply_failure()
        test_consequence_normalisation_typed_logs()
        test_mandatory_consequence_interpreter_precedes_observer_and_resume()
        test_consequence_observer_error_does_not_strand_roots()
        print('proofnet claim-completion cases: ok')
      end
    end)()
    _case()
  end
  print('machine/proofnet tests: ok')
end
