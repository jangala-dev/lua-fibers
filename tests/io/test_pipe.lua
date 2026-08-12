package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local fibers = require('fibers')
local Op = require('fibers.op')
local PureHost = require('fibers.embed.pure')
local SimulatedHost = require('tests.support.simulated_host')
local Handle = require('fibers.io.handle')
local HostHandles = require('tests.support.host_handles')
local HostError = require('fibers.io.error')
local file = require('fibers.file')

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
  end
end
local function assert_truthy(v, msg)
  if not v then
    error(msg or 'expected truthy', 2)
  end
end

-- Losing pipe options perform no host acquisition.
do
  local acquisitions = 0
  local host = SimulatedHost.new({
    auto_advance_time = false,
    pipe_factory = function(h, opts)
      acquisitions = acquisitions + 1
      return HostHandles.pipe_pair({ host = h, label = opts.label })
    end,
  })
  fibers.run(function()
    local result = fibers.perform(Op.always('winner'):or_else(file.submit_pipe_op({ label = 'loser' })))
    assert_eq(result, 'winner')
  end, { host = host })
  assert_eq(acquisitions, 0)
end

-- A pipe provides independently shaped readable and writable Streams.
do
  local host = SimulatedHost.new({ pipes = true, auto_advance_time = false })
  fibers.run(function()
    local reader, writer, err = file.pipe({ label = 'roundtrip', capacity = 32 })
    assert_truthy(reader, tostring(err))
    assert_truthy(reader:is_readable())
    assert_eq(reader:is_writable(), false)
    assert_truthy(writer:is_writable())
    assert_eq(writer:is_readable(), false)

    assert_eq(fibers.perform(writer:write_op('hello')), 5)
    assert_eq(writer:close('writer complete'), true)
    local bytes, read_err = fibers.perform(reader:read_all_op({ max = 64 }))
    assert_eq(bytes, 'hello', tostring(read_err))
    assert_eq(reader:close('reader complete'), true)
  end, { host = host })
end

-- Scope Closure closes both acquired handles when application code does not.
do
  local read_handle, write_handle
  local host = SimulatedHost.new({
    auto_advance_time = false,
    pipe_factory = function(h, opts)
      read_handle, write_handle = HostHandles.pipe_pair({ host = h, label = opts.label })
      return read_handle, write_handle
    end,
  })
  fibers.run(function()
    local reader, writer = file.pipe({ label = 'settled' })
    assert_truthy(reader)
    fibers.perform(writer:write_op('x'))
  end, { host = host })
  assert_eq(read_handle._closed, true)
  assert_eq(write_handle._closed, true)
end

-- Unsupported hosts return a structured expected error and leak no obligation.
do
  local reader, writer, err
  fibers.run(function()
    reader, writer, err = file.pipe({ label = 'unsupported' })
  end, {
    host = PureHost.new({
      now = function()
        return 0
      end,
      sleep = function()
        return true
      end,
    }),
  })
  assert_eq(reader, nil)
  assert_truthy(HostError.is_unsupported(err, 'pipe'))
end

-- Partial acquisition closes the handle which was created before failure.
do
  local read_handle
  local host = SimulatedHost.new({
    auto_advance_time = false,
    pipe_factory = function(h, opts)
      read_handle = HostHandles.pipe_pair({ host = h, label = opts.label })
      return read_handle, nil, HostError.system('pipe', 'create', 'writer creation failed')
    end,
  })
  local reader, writer, err
  fibers.run(function()
    reader, writer, err = file.pipe({ label = 'partial' })
  end, { host = host })
  assert_eq(reader, nil)
  assert_truthy(HostError.is(err, 'system'))
  assert_eq(read_handle._closed, true)
end

-- Stream admission failure closes both immediately held host handles.
do
  local bad_reader, writer
  local host = SimulatedHost.new({
    auto_advance_time = false,
    pipe_factory = function(h, opts)
      bad_reader = Handle.new({
        label = opts.label .. ':bad-reader',
        key = opts.label .. ':bad-reader',
        host = h,
        close = function()
          return true
        end,
      })
      local _reader
      _reader, writer = HostHandles.pipe_pair({ host = h, label = opts.label .. ':writer-source' })
      _reader:close('unused')
      return bad_reader, writer
    end,
  })
  local reader, writer_out, err
  fibers.run(function()
    reader, writer_out, err = file.pipe({ label = 'bad-stream' })
  end, { host = host })
  assert_eq(reader, nil)
  assert_truthy(err ~= nil)
  assert_eq(bad_reader._closed, true)
  assert_eq(writer._closed, true)
end

-- Directional close retains the familiar pipe semantics.
do
  local host = SimulatedHost.new({ pipes = true, auto_advance_time = false })
  fibers.run(function()
    local reader, writer = file.pipe({ label = 'directional-close' })
    assert_eq(fibers.perform(writer:write_op('retained')), 8)
    assert_eq(writer:close('writer complete'), true)
    assert_eq(fibers.perform(reader:read_all_op({ max = 32 })), 'retained')
    assert_eq(reader:close('reader complete'), true)
  end, { host = host })
end

-- Endpoint closure preserves a structured close error.
do
  local reader_handle, writer_handle
  local close_err = HostError.system('pipe', 'close', 'reader close failed', 'ECLOSE')
  local host = SimulatedHost.new({
    auto_advance_time = false,
    pipe_factory = function(h, opts)
      reader_handle, writer_handle = HostHandles.pipe_pair({ host = h, label = opts.label })
      reader_handle._close = function()
        return nil, close_err
      end
      return reader_handle, writer_handle
    end,
  })
  local observed
  local result = fibers.try_run(function()
    local reader, writer = file.pipe({ label = 'close-error' })
    writer:close('done')
    local ok, err = reader:close('test close error')
    assert_eq(ok, nil)
    observed = err
  end, { host = host })
  assert_eq(observed, close_err)
  assert_eq(result.ok, false, 'scope should retain the endpoint closure failure')
end

-- The public Pipe facility also works through the available native Linux host.
do
  local ok_linux, LinuxHost = pcall(require, 'fibers.io.luajit_linux')
  if ok_linux and LinuxHost.is_supported() then
    local host = LinuxHost.new()
    local result = fibers.try_run(function()
      local reader, writer, err = file.pipe({ label = 'native-pipe' })
      assert_truthy(reader, tostring(err))
      local writer_task = fibers.spawn(function()
        assert_eq(fibers.perform(writer:write_op('native')), 6)
        assert_eq(writer:close('writer complete'), true)
      end):label('native-pipe-writer')
      local bytes, read_err = fibers.perform(reader:read_all_op({ max = 64 }))
      assert_eq(bytes, 'native', tostring(read_err))
      assert_eq(reader:close('reader complete'), true)
      writer_task:await()
    end, { host = host })
    host:close()
    assert_truthy(result.ok, result:tostring())
  end
end

print('tests/io/test_pipe.lua: ok')
