package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './src/?/?.lua',
  './reference/?.lua',
  './reference/?/init.lua',
  './reference/?/?.lua',
  './?.lua',
  './?/init.lua',
  './?/?.lua',
  package.path,
}, ';')

local Common = require('tests.embedding.hosts.common')

local ok_mod, NixioHost = pcall(require, 'fibers.host.nixio')
Common.assert_truthy(ok_mod, 'nixio host module should be require-able')
Common.assert_truthy(type(NixioHost.is_supported) == 'function', 'nixio host should expose is_supported')
Common.assert_truthy(type(NixioHost.new) == 'function', 'nixio host should expose new')

if not NixioHost.is_supported() then
  return Common.skip('tests/hosts/test_nixio.lua', 'nixio backend not available')
end

local ok_nixio, nixio = pcall(require, 'nixio')
if not ok_nixio or type(nixio) ~= 'table' then
  return Common.skip('tests/hosts/test_nixio.lua', 'nixio module not available')
end
if type(nixio.pipe) ~= 'function' then
  return Common.skip('tests/hosts/test_nixio.lua', 'nixio.pipe unavailable')
end

local function make_pipe()
  local r, w = nixio.pipe()
  Common.assert_truthy(r and w, 'nixio.pipe should return read and write descriptors')
  local closed = false
  local function close_one(x)
    if x and type(x.close) == 'function' then
      pcall(function()
        x:close()
      end)
    end
  end
  local function write_byte(_ch)
    if type(w.writeall) == 'function' then
      return w:writeall('x')
    end
    if type(w.write) == 'function' then
      local n, err = w:write('x')
      if n == true or n == 1 then
        return true
      end
      return nil, err or ('short write: ' .. tostring(n))
    end
    return nil, 'nixio write method unavailable'
  end
  return {
    read_key = r,
    write_key = w,
    write_byte = write_byte,
    close = function()
      if closed then
        return
      end
      closed = true
      close_one(r)
      close_one(w)
    end,
  }
end

local function with_host_pipe(label, fn)
  local host = NixioHost.new()
  local pipe = make_pipe()
  local ok, err = pcall(function()
    fn(label, host, pipe)
  end)
  Common.cleanup(host, pipe)
  if not ok then
    error(err, 0)
  end
end

with_host_pipe('nixio:readiness', Common.readiness_smoke)
with_host_pipe('nixio:write-readiness', Common.write_readiness_smoke)
with_host_pipe('nixio:readiness-beats-timeout', Common.readiness_beats_timeout_smoke)
with_host_pipe('nixio:timeout-beats-unready', Common.timeout_beats_unready_smoke)

print('tests/hosts/test_nixio.lua: ok')
