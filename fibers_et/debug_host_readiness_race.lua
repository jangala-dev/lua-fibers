package.path = table.concat({'./?.lua','./?/init.lua','./?/?.lua',package.path}, ';')

local backend = assert(arg[1], 'usage: lua debug_host_readiness_race.lua BACKEND')
local fibers = require('fibers')
local Host = require('fibers.host')

local function make_backend(name)
  if name == 'nixio' then
    local nixio = assert(require('nixio'))
    local r, w = assert(nixio.pipe())
    local pipe = {
      read_key = r,
      write_byte = function()
        if type(w.writeall) == 'function' then return w:writeall('x') end
        local n, err = w:write('x')
        if n == true or n == 1 then return true end
        return nil, err or ('short write: ' .. tostring(n))
      end,
      close = function()
        pcall(function() r:close() end)
        pcall(function() w:close() end)
      end,
    }
    return require('fibers.host.nixio').new(), pipe
  elseif name == 'luaposix' then
    local support = assert(require('tests.support.posix_linux'))
    assert(support.available, support.reason)
    return require('fibers.host.luaposix').new(), support.make_pipe(assert)
  elseif name == 'luajit_linux' then
    local support = assert(require('tests.support.ffi_linux'))
    assert(support.available, support.reason)
    return require('fibers.host.luajit_linux').new(), support.make_pipe()
  elseif name == 'cffi_linux' then
    local support = assert(require('tests.support.cffi_linux'))
    assert(support.available, support.reason)
    return require('fibers.host.cffi_linux').new(), support.make_pipe()
  end
  error('unknown backend: ' .. tostring(name))
end

local host, pipe = make_backend(backend)
local rt = fibers.Runtime.new({ host = host })
local src = fibers.Readiness.new(pipe.read_key, 'read', backend .. ':debug-readiness')
local winner

rt:spawn_raw(function()
  winner = rt:perform(fibers.choice(
    src:readable_op():map(function() return 'readiness' end),
    fibers.sleep_op(0.25):map(function() return 'timeout' end)
  ))
end, backend .. ':debug-race')

local ok, err = pipe.write_byte('x')
assert(ok, err)

local first = rt:run()
print('first status:', first.tag, first.kind or '')
local waits = first.interests or first.waits or {}
print('wait count:', #waits)
for i, w in ipairs(waits) do
  print(string.format(
    '  wait[%d] kind=%s external_kind=%s mode=%s key=%s deadline=%s id=%s',
    i, tostring(w.kind), tostring(w.external_kind), tostring(w.mode),
    tostring(w.readiness_key), tostring(w.deadline), tostring(w.id)))
end

local deadline = Host.earliest_deadline(waits)
print('now before block:', rt:now())
print('deadline:', deadline)
print('timeout_ms:', Host.timeout_ms(rt, deadline))

local before = rt:now()
local progressed, reason = host:block(rt, waits, first, {})
local after = rt:now()
print('host block:', tostring(progressed), tostring(reason), 'elapsed=', after - before)
print('readiness state after block:',
  tostring(src._location and src._location.value and src._location.value.read))

local second = rt:run()
print('second status:', second.tag, second.kind or '')
print('winner:', tostring(winner))

pcall(function() pipe:close() end)
pcall(function() host:close() end)
