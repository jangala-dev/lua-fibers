-- tests/test_io-socket.lua
--
-- Integration tests for:
--   - fibers.io.socket
--   - fibers.io.fd_backend
--   - fibers.io.stream
--
-- Uses the real scheduler, ops and wait/waitset machinery.
print('testing: fibers.io.socket')

-- look one level up
package.path = "../src/?.lua;" .. package.path

-- test_socket.lua
--
-- Simple assertion-based checks for fibers.io.socket over AF_UNIX.

local fibers    = require 'fibers'
local socket_mod = require 'fibers.io.socket'

local perform = fibers.perform

local function test_unix_socket_roundtrip(scope)
  -- Construct a unique path under /tmp for this test run.
  local base = os.getenv("TMPDIR") or "/tmp"
  local path = string.format("%s/fibers_socket_test.%d.%d",
    base, os.time(), math.random(1e6))

  -- Start listening server.
  local server, err = socket_mod.listen_unix(path, { ephemeral = true })
  assert(server, "listen_unix failed: " .. tostring(err))

  -- Server fiber: accept one connection, echo a response, then close.
  scope:spawn(function(_)
    local s, aerr = server:accept()
    assert(s, "server accept failed: " .. tostring(aerr))

    local msg, cnt, rerr = perform(s:read_string_op{
      min    = 5,
      max    = 5,
      eof_ok = true,
    })

    assert(rerr == nil, "server read_string_op error: " .. tostring(rerr))
    assert(cnt == 5, "server read_string_op read " .. tostring(cnt) .. " bytes, expected 5")
    assert(msg == "hello", ("server received %q, expected %q"):format(tostring(msg), "hello"))

    local n, werr = perform(s:write_string_op("world"))
    assert(werr == nil, "server write_string_op error: " .. tostring(werr))
    assert(n == 5, "server write_string_op wrote " .. tostring(n) .. " bytes, expected 5")

    local okc, cerr = s:close()
    assert(okc, "server stream close failed: " .. tostring(cerr))

    local oks, serr = server:close()
    assert(oks, "server socket close failed: " .. tostring(serr))
  end)

  -- Client side: connect, send "hello", read "world".
  local client, cerr = socket_mod.connect_unix(path)
  assert(client, "connect_unix failed: " .. tostring(cerr))

  local n, werr = perform(client:write_string_op("hello"))
  assert(werr == nil, "client write_string_op error: " .. tostring(werr))
  assert(n == 5, "client write_string_op wrote " .. tostring(n) .. " bytes, expected 5")

  local resp, cnt, rerr = perform(client:read_string_op{
    min    = 5,
    max    = 5,
    eof_ok = true,
  })

  assert(rerr == nil, "client read_string_op error: " .. tostring(rerr))
  assert(cnt == 5, "client read_string_op read " .. tostring(cnt) .. " bytes, expected 5")
  assert(resp == "world", ("client received %q, expected %q"):format(tostring(resp), "world"))

  local okc, cclose_err = client:close()
  assert(okc, "client stream close failed: " .. tostring(cclose_err))
end

local function main(scope)
  test_unix_socket_roundtrip(scope)
end

fibers.run(main)

print("test_socket.lua: all assertions passed")
