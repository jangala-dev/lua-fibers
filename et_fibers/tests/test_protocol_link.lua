return function()
  local Protocol = require('et.protocol')
  local Kernel = require('et.machine.kernel')
  local FrontierLayer = require('et.machine.frontier')
  local Link = Protocol.Link
  local Status = Kernel.Status
  local Phase = Kernel.Phase
  local View = FrontierLayer.View
  local Values = Protocol.Values
  local Cell = require('et.resources.cell')
  local Queue = require('et.resources.queue')
  local Channel = require('et.resources.channel')

  local function assert_status(x, tag, msg)
    if not x or x.tag ~= tag then
      error((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(x and x.tag), 2)
    end
    return x.value
  end

  local function assert_eq(actual, expected, msg)
    if actual ~= expected then
      error((msg or 'assertion failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
  end

  local required = { 'snapshot', 'initial', 'claim', 'merge', 'prepare', 'commit' }
  for i = 1, #required do
    assert(type(Link[required[i]]) == 'function', 'Protocol.Link.' .. required[i] .. ' must exist')
  end

  local cell = Cell.new(0, 'link-cell')
  local cell_view = View.open('link-cell-view')
  local cell_fragment = Phase.with('search', function(token)
    local snap = assert_status(Link.snapshot(cell_view, cell), 'found', 'cell snapshot')
    local f0 = assert_status(Link.initial(cell_view, cell, snap, token), 'found', 'cell initial')
    local r = assert_status(Link.claim(cell_view, cell, f0, {
      kind = 'access',
      request = { tag = 'set', value = 41 },
    }, token), 'found', 'cell claim')
    assert_eq(Values.unpack(r.values), true, 'cell set completion')
    assert(r.dependencies and r.dependencies.by_resource[cell] == 0, 'cell claim records dependency')
    return r.fragment
  end)
  local prepared_cell = assert_status(Phase.with('prepare', function(token)
    return Link.prepare(cell, cell_fragment, token)
  end), 'found', 'cell prepare')
  assert_status(Phase.with('commit', function(token)
    return Link.commit(prepared_cell, token)
  end), 'found', 'cell commit')
  assert_eq(cell.value, 41, 'Link.commit applies prepared cell fragment')

  local queue = Queue.new({}, 'link-queue')
  local queue_view = View.open('link-queue-view')
  local wait_status = Phase.with('search', function(token)
    return Link.claim(queue_view, queue, nil, {
      kind = 'await',
      request = { tag = 'nonempty' },
    }, token)
  end)
  assert_eq(wait_status.tag, 'pending', 'empty queue await blocks through Link.claim')
  assert(wait_status.detail and wait_status.detail.dependencies and wait_status.detail.dependencies.by_resource[queue] == 0,
    'queue await exposes dependency data')

  local channel = Channel.new('link-channel')
  local channel_view = View.open('link-channel-view')
  Phase.with('search', function(token)
    local put = assert_status(Link.claim(channel_view, channel, nil, {
      kind = 'open_claim',
      request = { tag = 'send', values = Values.pack('hello') },
    }, token), 'found', 'channel put open claim').open_claim
    local get = assert_status(Link.claim(channel_view, channel, nil, {
      kind = 'open_claim',
      request = { tag = 'recv' },
    }, token), 'found', 'channel get open claim').open_claim
    local matches = assert_status(Link.merge(channel_view, channel, { kind = 'complete', open_claims = { put, get } }, token), 'found', 'channel claim-completion merge')
    assert_eq(#matches, 1, 'channel put/get produce one match')
    assert_eq(Values.unpack(matches[1].assignments[get.id]), 'hello', 'channel merge completes receiver')
  end)

  print('protocol link transcript tests: ok')
end
