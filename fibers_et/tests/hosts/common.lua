package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local fibers = require('fibers')
local Runner = require('fibers.runner')

local Common = {}

function Common.fail(msg) error(msg, 2) end
function Common.assert_truthy(v, msg) if not v then Common.fail(msg or 'expected truthy') end end
function Common.assert_eq(a, b, msg) if a ~= b then Common.fail((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
function Common.assert_status(st, tag, msg) if not st or st.tag ~= tag then Common.fail((msg or 'status mismatch') .. ': expected ' .. tostring(tag) .. ', got ' .. tostring(st and st.tag)) end end

function Common.skip(name, reason)
  local result = { status = 'skip', name = name, reason = tostring(reason or 'not available') }
  if not rawget(_G, '_FIBERS_TEST_HARNESS') then
    print(name .. ': skip (' .. result.reason .. ')')
  end
  return result
end

function Common.close_quietly(x)
  if x and type(x.close) == 'function' then pcall(function() x:close() end) end
end

function Common.cleanup(host, pipe)
  Common.close_quietly(pipe)
  Common.close_quietly(host)
end

local function run_host(name, host, max_iterations)
  return function(rt)
    return Runner.run(rt, { host = host, max_iterations = max_iterations or 40 })
  end
end

function Common.readiness_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.read_key ~= nil, name .. ' pipe must expose read_key')
  Common.assert_truthy(type(pipe.write_byte) == 'function', name .. ' pipe must expose write_byte')

  local rt = fibers.Runtime.new({ host = host })
  local src = fibers.Source.readiness(pipe.read_key, 'read', name .. '-readiness')
  local seen, seen_key, seen_mode

  rt:spawn_raw(function()
    seen, seen_key, seen_mode = rt:perform(src:readable_op())
  end, name .. '-reader')

  local ok, err = pipe.write_byte('x')
  Common.assert_truthy(ok, name .. ' pipe write failed: ' .. tostring(err))

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' readiness runner')
  Common.assert_eq(seen, true, name .. ' should deliver readiness')
  Common.assert_eq(seen_key, pipe.read_key, name .. ' should preserve readiness key')
  Common.assert_eq(seen_mode, 'read', name .. ' should deliver read mode')
end

function Common.write_readiness_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.write_key ~= nil, name .. ' pipe must expose write_key')

  local rt = fibers.Runtime.new({ host = host })
  local src = fibers.Source.readiness(pipe.write_key, 'write', name .. '-write-readiness')
  local seen, seen_key, seen_mode

  rt:spawn_raw(function()
    seen, seen_key, seen_mode = rt:perform(src:writable_op())
  end, name .. '-writer-ready')

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' write readiness runner')
  Common.assert_eq(seen, true, name .. ' should deliver write readiness')
  Common.assert_eq(seen_key, pipe.write_key, name .. ' should preserve write readiness key')
  Common.assert_eq(seen_mode, 'write', name .. ' should deliver write mode')
end

function Common.ready_source_smoke(name, host, key, mode)
  mode = mode or 'read'
  local rt = fibers.Runtime.new({ host = host })
  local src = fibers.Source.readiness(key, mode, name .. '-ready-source')
  local seen, seen_key, seen_mode

  rt:spawn_raw(function()
    if mode == 'write' or mode == 'wr' then
      seen, seen_key, seen_mode = rt:perform(src:writable_op())
    else
      seen, seen_key, seen_mode = rt:perform(src:readable_op())
    end
  end, name .. '-ready-source-waiter')

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' ready-source runner')
  Common.assert_eq(seen, true, name .. ' should deliver readiness')
  Common.assert_eq(seen_key, key, name .. ' should preserve readiness key')
  Common.assert_eq(seen_mode, (mode == 'write' or mode == 'wr') and 'write' or mode, name .. ' should deliver readiness mode')
end

function Common.readiness_beats_timeout_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.read_key ~= nil, name .. ' pipe must expose read_key')
  Common.assert_truthy(type(pipe.write_byte) == 'function', name .. ' pipe must expose write_byte')

  local rt = fibers.Runtime.new({ host = host })
  local src = fibers.Source.readiness(pipe.read_key, 'read', name .. '-choice-readiness')
  local winner

  rt:spawn_raw(function()
    winner = rt:perform(fibers.choice(
      src:readable_op():map(function() return 'readiness' end),
      fibers.sleep_op(0.25):map(function() return 'timeout' end)
    ))
  end, name .. '-readiness-v-timeout')

  local ok, err = pipe.write_byte('x')
  Common.assert_truthy(ok, name .. ' pipe write failed: ' .. tostring(err))

  local st = run_host(name, host)(rt)
  Common.assert_status(st, 'found', name .. ' readiness should beat timeout')
  Common.assert_eq(winner, 'readiness', name .. ' should choose readiness over later timeout')
end

function Common.timeout_beats_unready_smoke(name, host, pipe)
  Common.assert_truthy(pipe and pipe.read_key ~= nil, name .. ' pipe must expose read_key')

  local rt = fibers.Runtime.new({ host = host })
  local src = fibers.Source.readiness(pipe.read_key, 'read', name .. '-timeout-readiness')
  local winner

  rt:spawn_raw(function()
    winner = rt:perform(fibers.choice(
      src:readable_op():map(function() return 'readiness' end),
      fibers.sleep_op(0.01):map(function() return 'timeout' end)
    ))
  end, name .. '-timeout-v-readiness')

  local st = run_host(name, host, 80)(rt)
  Common.assert_status(st, 'found', name .. ' timeout should complete')
  Common.assert_eq(winner, 'timeout', name .. ' should choose timeout when pipe is unready')
end


function Common.handle_stream_pipe_smoke(name, host, Fd)
  local fibers = require('fibers')
  local Handle = require('fibers.host.handle')
  local r, w, perr = Fd.pipe({ host = host, name = name .. ':pipe' })
  Common.assert_truthy(r and w, name .. ' pipe failed: ' .. tostring(perr))
  local handle = Handle.duplex(r, w, { host = host, name = name .. ':duplex' })
  local rt = fibers.Runtime.new({ host = host })
  local region = fibers.Region.new(name .. ':region')
  local got, flushed, stream

  rt:spawn_raw(function()
    stream = rt:perform(fibers.Stream.open_handle_op(region, handle, { name = name .. ':stream', capacity = 64, chunk_size = 16 }))
    rt:perform(stream:writer():write_op('hello'))
    flushed = rt:perform(stream:writer():flush_op())
    got = rt:perform(stream:reader():read_exactly_op(5))
    rt:perform(stream:shutdown_op('test complete'))
  end, name .. ':flow')

  local st = Runner.run(rt, { host = host, max_iterations = 200 })
  Common.assert_status(st, 'found', name .. ' stream pipe runner')
  Common.assert_eq(flushed, true, name .. ' stream flush should succeed')
  Common.assert_eq(got, 'hello', name .. ' stream should loop bytes through pipe')
  handle:close('test')
end

return Common
