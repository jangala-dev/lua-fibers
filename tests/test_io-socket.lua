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
package.path = '../src/?.lua;' .. package.path

local fibers     = require 'fibers'
local socket_mod = require 'fibers.io.socket'

local perform = fibers.perform

math.randomseed(os.time())

local function read_exact(stream, n, who)
	local data, cnt, err = perform(stream:core_read_op {
		min    = n,
		max    = n,
		eof_ok = true,
	})
	assert(err == nil, (who or 'read') .. ' error: ' .. tostring(err))
	assert(cnt == n, (who or 'read') .. ' read ' .. tostring(cnt) .. ' bytes, expected ' .. tostring(n))
	return data
end

local function write_all(stream, s, who)
	local n, err = perform(stream:write_op(s))
	assert(err == nil, (who or 'write') .. ' error: ' .. tostring(err))
	assert(n == #s, (who or 'write') .. ' wrote ' .. tostring(n) .. ' bytes, expected ' .. tostring(#s))
end

local function close_ok(obj, who)
	local ok, err = obj:close()
	assert(ok, (who or 'close') .. ' failed: ' .. tostring(err))
end

local function pick_listen_port()
	-- Avoid privileged ports; choose from a broad high range.
	return math.random(30000, 55000)
end

local function listen_inet_retry(host, tries)
	tries = tries or 32
	local last_err

	for _ = 1, tries do
		local port = pick_listen_port()
		local s, err = socket_mod.listen_inet(host, port)
		if s then
			return s, port
		end
		last_err = err
	end

	return nil, nil, ('failed to bind IPv4 listener after retries: %s'):format(tostring(last_err))
end

local function test_unix_socket_roundtrip(scope)
	-- Construct a unique path under /tmp for this test run.
	local base = os.getenv('TMPDIR') or '/tmp'
	local path = string.format('%s/fibers_socket_test.%d.%d',
		base, os.time(), math.random(1, 1000000))

	-- Start listening server.
	local server, err = socket_mod.listen_unix(path, { ephemeral = true })
	assert(server, 'listen_unix failed: ' .. tostring(err))

	-- Server fibre: accept one connection, echo a response, then close.
	scope:spawn(function ()
		local s, aerr = server:accept()
		assert(s, 'server accept failed: ' .. tostring(aerr))

		local msg = read_exact(s, 5, 'server(unix) read')
		assert(msg == 'hello', ('server(unix) received %q, expected %q'):format(tostring(msg), 'hello'))

		write_all(s, 'world', 'server(unix) write')

		close_ok(s, 'server(unix) stream close')
		close_ok(server, 'server(unix) socket close')
	end)

	-- Client side: connect, send "hello", read "world".
	local client, cerr = socket_mod.connect_unix(path)
	assert(client, 'connect_unix failed: ' .. tostring(cerr))

	write_all(client, 'hello', 'client(unix) write')

	local resp = read_exact(client, 5, 'client(unix) read')
	assert(resp == 'world', ('client(unix) received %q, expected %q'):format(tostring(resp), 'world'))

	close_ok(client, 'client(unix) stream close')
end

local function test_inet_socket_roundtrip(scope)
	assert(socket_mod.AF_INET, 'AF_INET not exported by fibers.io.socket')

	local host = '127.0.0.1'

	-- Start listening server on a random high port.
	local server, port, lerr = listen_inet_retry(host, 64)
	assert(server, lerr or 'listen_inet failed')

	-- Server fibre: accept one connection, echo a response, then close.
	scope:spawn(function ()
		local s, aerr = server:accept()
		assert(s, 'server accept failed: ' .. tostring(aerr))

		local msg = read_exact(s, 5, 'server(inet) read')
		assert(msg == 'hello', ('server(inet) received %q, expected %q'):format(tostring(msg), 'hello'))

		write_all(s, 'world', 'server(inet) write')

		close_ok(s, 'server(inet) stream close')
		close_ok(server, 'server(inet) socket close')
	end)

	-- Client side: connect over loopback, explicitly binding source address.
	-- bind_port=0 asks the kernel to choose an ephemeral source port.
	local client, cerr = socket_mod.connect_inet(host, port, {
		bind_host = '127.0.0.1',
		bind_port = 0,
	})
	assert(client, 'connect_inet failed: ' .. tostring(cerr))

	write_all(client, 'hello', 'client(inet) write')

	local resp = read_exact(client, 5, 'client(inet) read')
	assert(resp == 'world', ('client(inet) received %q, expected %q'):format(tostring(resp), 'world'))

	close_ok(client, 'client(inet) stream close')
end

local function main(scope)
	test_unix_socket_roundtrip(scope)
	test_inet_socket_roundtrip(scope)
end

fibers.run(main)

print('test_io-socket.lua: all assertions passed')
