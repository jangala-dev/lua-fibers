return function()
  local function read_file(path)
    local f = assert(io.open(path, 'r'))
    local s = f:read('*a')
    f:close()
    return s
  end

  local function exists(path)
    local f = io.open(path, 'r')
    if f then f:close(); return true end
    return false
  end

  local function requires(src)
    local out = {}
    for dep in src:gmatch("require%s*%(%s*['\"]([^'\"]+)['\"]%s*%)") do
      out[#out + 1] = dep
    end
    return out
  end

  local Protocol = require('et.protocol')
  local expected_protocol_exports = {
    Link = true,
    Values = true,
    Effect = true,
  }
  for name in pairs(expected_protocol_exports) do
    assert(Protocol[name] ~= nil, 'Protocol.' .. name .. ' must be exported')
  end
  for name in pairs(Protocol) do
    assert(expected_protocol_exports[name], 'unexpected Protocol export: ' .. tostring(name))
  end
  assert(Protocol.Result == nil, 'result language is machine-internal')
  assert(Protocol.Status == nil, 'Status alias must not be exported')
  assert(Protocol.Util == nil, 'Util must not be exported')
  assert(Protocol.Raw == nil, 'Raw escape hatch must not be exported')
  assert(Protocol.Phase == nil and Protocol.Origin == nil and Protocol.Dependency == nil, 'machine bookkeeping must not be public protocol')
  assert(Protocol.Consequence == nil and Protocol.View == nil and Protocol.Obligation == nil, 'machine bookkeeping must live in et.machine layers')
  assert(Protocol.Resource == nil, 'removed Resource API must not be exported')
  assert(Protocol.Primitive == nil and Protocol.primitive == nil, 'removed primitive API must not be exported')

  local Machine = require('et.machine')
  local expected_machine_exports = {
    Kernel = true,
    Frontier = true,
    Attempt = true,
    ProofNet = true,
    World = true,
    Commit = true,
  }
  for name in pairs(expected_machine_exports) do
    assert(type(Machine[name]) == 'table', 'Machine.' .. name .. ' must be exported')
  end
  for name in pairs(Machine) do
    assert(expected_machine_exports[name], 'unexpected Machine export: ' .. tostring(name))
  end
  assert(Machine.Result == nil, 'Machine.Result must not be a top-level machine export')
  assert(Machine.Protocol == nil, 'Machine.Protocol must not be exported')
  assert(Machine.Kernel.Origin == nil, 'Origin must live in Frontier, not Kernel')
  assert(Machine.Kernel.Dependency == nil, 'Dependency must live in Frontier, not Kernel')
  assert(Machine.Kernel.Consequence == nil, 'Consequence must live in Frontier/Commit, not Kernel')
  assert(Machine.Frontier.Origin ~= nil and Machine.Frontier.Dependency ~= nil, 'Frontier must own origins and dependencies')
  assert(Machine.Frontier.Consequence ~= nil, 'Frontier must own selected consequence evidence')

  -- No compatibility aliases that hide canonical organs.
  assert(Machine.Frontier.ExpansionMemo == nil, 'Frontier.ExpansionMemo compatibility alias must not be exported; use Frontier.Memo')
  assert(Machine.World.search == nil, 'World.search compatibility alias must not be exported; use ProofNet.find')
  assert(Machine.World.search_multi == nil, 'World.search_multi compatibility alias must not be exported')
  assert(Machine.Commit.try_build == nil, 'Commit.try_build compatibility alias must not be exported; use Commit.Certificate.try_build')
  assert(Machine.Commit.apply == nil, 'Commit.apply compatibility wrapper must not be exported; use certificate:apply()')

  -- Protocol is the public participant contract and must not depend on machine/runtime.
  assert(exists('et/protocol.lua'), 'missing et.protocol')
  local protocol_src = read_file('et/protocol.lua')
  for _, dep in ipairs(requires(protocol_src)) do
    assert(not dep:match('^et%.machine'), 'et.protocol must not depend on machine')
    assert(not dep:match('^et%.runtime'), 'et.protocol must not depend on runtime')
  end

  local machine_files = {
    ['et/machine/kernel.lua'] = {
      may_require = { ['et.kernel'] = true },
    },
    ['et/machine/frontier.lua'] = {
      may_require = { ['et.op'] = true, ['et.machine.kernel'] = true, ['et.protocol'] = true },
    },
    ['et/machine/proofnet.lua'] = {
      may_require = { ['et.machine.kernel'] = true, ['et.protocol'] = true, ['et.machine.frontier'] = true },
    },
    ['et/machine/world.lua'] = {
      may_require = { ['et.machine.kernel'] = true, ['et.protocol'] = true, ['et.machine.frontier'] = true },
    },
    ['et/machine/commit.lua'] = {
      may_require = { ['et.machine.kernel'] = true, ['et.protocol'] = true, ['et.machine.frontier'] = true, ['et.machine.world'] = true, ['et.machine.proofnet'] = true },
    },
    ['et/machine/attempt.lua'] = {
      may_require = { ['et.machine.frontier'] = true },
    },
  }

  for path, rule in pairs(machine_files) do
    assert(exists(path), 'missing machine airframe file: ' .. path)
    local src = read_file(path)
    for _, dep in ipairs(requires(src)) do
      assert(rule.may_require[dep], path .. ' has non-linear machine dependency on ' .. dep)
    end
  end

  for path in pairs(machine_files) do
    if path ~= 'et/machine/kernel.lua' and path ~= 'et/machine/attempt.lua' then
      local src = read_file(path)
      assert(src:find('Protocol%.Link') or src:find('local Link = Protocol%.Link') or src:find('Protocol = require'), path .. ' should speak through Protocol when it talks to resources')
    end
  end

  -- The machine package has a small number of model-bearing organs.
  local expected_organs = {
    ['kernel.lua'] = true,
    ['frontier.lua'] = true,
    ['proofnet.lua'] = true,
    ['world.lua'] = true,
    ['commit.lua'] = true,
    ['attempt.lua'] = true, -- compatibility alias
  }
  local p = io.popen('find et/machine -maxdepth 1 -type f -name "*.lua"')
  for line in p:lines() do
    local name = line:match('([^/]+)$')
    assert(expected_organs[name], 'unexpected machine internal file: ' .. line)
    expected_organs[name] = 'seen'
  end
  p:close()
  for name, state in pairs(expected_organs) do
    assert(state == 'seen', 'missing machine internal file: ' .. name)
  end

  -- The top-level machine facade is the production entry to machine organs.
  local facade_src = read_file('et/machine.lua')
  local allowed_facade = {
    ['et.machine.kernel'] = true,
    ['et.machine.frontier'] = true,
    ['et.machine.proofnet'] = true,
    ['et.machine.world'] = true,
    ['et.machine.commit'] = true,
  }
  for _, dep in ipairs(requires(facade_src)) do
    assert(allowed_facade[dep], 'machine facade requires unexpected module ' .. dep)
  end

  -- Production code imports package facades, not package organs.
  local production_files = {
    'et/op.lua',
    'et/protocol.lua',
    'et/runtime.lua',
    'et/runtime/engine.lua',
    'et/resources/cell.lua',
    'et/resources/channel.lua',
    'et/resources/queue.lua',
  }

  for _, file in ipairs(production_files) do
    assert(exists(file), 'missing production source file: ' .. file)
    local src = read_file(file)
    for _, dep in ipairs(requires(src)) do
      local is_runtime_facade = file == 'et/runtime.lua'
      if dep:match('^et%.machine%.') then
        assert(false, file .. ' must require et.machine facade, not ' .. dep)
      end
      if dep:match('^et%.runtime%.') and not is_runtime_facade then
        assert(false, file .. ' must require et.runtime facade, not ' .. dep)
      end
    end
  end

  -- Resources are protocol authors, not machine drivers.
  local resource_files = {
    'et/resources/cell.lua',
    'et/resources/channel.lua',
    'et/resources/queue.lua',
  }

  for _, file in ipairs(resource_files) do
    local src = read_file(file)
    local requires_protocol = false
    for _, dep in ipairs(requires(src)) do
      if dep == 'et.protocol' then requires_protocol = true end
      assert(dep ~= 'et.machine', file .. ' must not require machine')
      assert(dep ~= 'et.runtime', file .. ' must not require runtime')
    end
    assert(requires_protocol, file .. ' should use et.protocol')
    assert(not src:find('Machine%.'), file .. ' must not mention Machine')
  end

  do
    local primitive_resource_files = {
      ['et/resources/cell.lua'] = 'cell',
      ['et/resources/queue.lua'] = 'queue',
      ['et/resources/channel.lua'] = 'channel',
    }
    for file, name in pairs(primitive_resource_files) do
      local src = read_file(file)
      assert(src:find('Protocol%.Link%.resource'), name .. ' should implement the Protocol.Link resource boundary')
      assert(not src:find('Protocol%.Raw'), name .. ' should not use the raw protocol escape hatch')
      assert(not src:find('Phase%.'), name .. ' primitive should not touch phase tokens directly')
      assert(not src:find('Dependency%.'), name .. ' primitive should not touch dependency sets directly')
      assert(not src:find('Origin%.'), name .. ' primitive should not touch origins directly')
      assert(not src:find('Resource%.mark'), name .. ' resource should be marked by Protocol.Link.resource')
      assert(not src:find('Result%.'), name .. ' primitive should use primitive outcomes/context helpers, not raw Result')
      assert(not src:find('Status%.'), name .. ' primitive should use primitive outcomes/context helpers, not raw Status')
    end
  end

  -- Tests are allowed, and expected, to reach into machine internals directly.
  local test_files = {
    'tests/test_algebra_principled.lua',
    'tests/test_expansion_memo.lua',
    'tests/test_frontier.lua',
    'tests/test_ms4.lua',
    'tests/test_ms5.lua',
    'tests/test_ms6.lua',
    'tests/test_ms65_clean.lua',
    'tests/test_ms7.lua',
    'tests/test_ms8.lua',
    'tests/test_ms9.lua',
    'tests/test_regression_algebra.lua',
    'tests/test_link_custom_resources.lua',
    'tests/test_protocol_link.lua',
  }

  local saw_internal_test_import = false
  for _, file in ipairs(test_files) do
    assert(exists(file), 'missing test source file: ' .. file)
    local src = read_file(file)
    for _, dep in ipairs(requires(src)) do
      assert(dep ~= 'et.machine', file .. ' should import machine organs directly, not et.machine facade')
      assert(dep ~= 'et.machine.result', file .. ' should use et.protocol for result language')
      assert(dep ~= 'et.machine.protocol', file .. ' should use et.protocol for participant contracts')
      if dep:match('^et%.machine%.') then saw_internal_test_import = true end
    end
  end
  assert(saw_internal_test_import, 'tests should exercise machine internals directly')

  -- Op and Protocol must stay independent of machine/runtime.
  local Op = require('et.op')
  assert(Op.open_claim ~= nil, 'Op.open_claim must be exported for open claim operations')
  assert(Op.offer == nil, 'removed Op.offer name must not be exported')

  local op_src = read_file('et/op.lua')
  for _, dep in ipairs(requires(op_src)) do
    assert(not dep:match('^et%.machine'), 'et.op must not depend on machine')
    assert(not dep:match('^et%.runtime'), 'et.op must not depend on runtime')
    assert(not dep:match('^et%.protocol'), 'et.op must not depend on protocol')
  end

  -- Old flat internals and old granular machine organs must be gone.
  local removed = {
    'et/status.lua','et/util.lua','et/phase.lua','et/origin.lua','et/dependency.lua',
    'et/resource.lua','et/consequence.lua','et/view.lua','et/evidence.lua','et/frontier.lua',
    'et/frame.lua','et/proofsearch.lua','et/certificate.lua','et/obligation.lua',

    'et/machine/result.lua','et/machine/protocol.lua',
    'et/machine/status.lua','et/machine/util.lua','et/machine/phase.lua','et/machine/origin.lua',
    'et/machine/dependency.lua','et/machine/consequence.lua','et/machine/resource.lua',
    'et/machine/view.lua','et/machine/evidence.lua',
    'et/machine/frame.lua','et/machine/certificate.lua',
    'et/machine/obligation.lua','et/machine/absence.lua','et/machine/expansion_memo.lua',
    'et/machine/configuration.lua','et/machine/candidate.lua',
  }
  for _, path in ipairs(removed) do
    assert(not exists(path), 'removed internal still exists: ' .. path)
  end

  print('dependency protocol-boundary tests: ok')
end
