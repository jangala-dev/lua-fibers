package.path = table.concat({
  './?.lua', './?/init.lua', './?/?.lua',
  package.path,
}, ';')

local Result = require('et.machine.kernel').Status
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
  local c = Cell.new(0, 'ms4-cell-update')
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
  local c = Cell.new(0, 'ms4-or-else-primary')
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
  local c = Cell.new(0, 'ms4-stale-retry')
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
  local c = Cell.new(0, 'ms4-stale-or-else')
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
  local c = Cell.new(10, 'ms4-map-single')
  local result
  rt:spawn(function()
    result = rt:perform(c:get_op(Op):map(function(v) return v + 1 end))
  end, 'map-single')
  assert_status(rt:run(), 'found')
  assert_eq(result, 11, 'deferred map with one return resumes with the value, not a row table')
end

local function test_deferred_map_multiple_returns_resolve_to_row()
  local rt = Runtime.new()
  local c = Cell.new(10, 'ms4-map-multi')
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
  print('milestone 4 resource proof-search tests: ok')
end
