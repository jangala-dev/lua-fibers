-- scoped_line_server.lua
--
-- Single-file runnable example for the fibers runtime:
--   * UNIX-domain line server
--   * per-connection worker pool using channels
--   * external “work” simulated via /bin/sh (sleep + tr)
--   * timeouts and cancellation via ops + scopes
--   * no pcall in application logic: failures propagate via scopes
--
-- Run:
--   lua scoped_line_server.lua
--
-- Optional:
--   SH=/usr/bin/sh lua demo.lua

package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local socket = require 'fibers.io.socket'
local sleep  = require 'fibers.sleep'
local chan   = require 'fibers.channel'
local exec   = require 'fibers.io.exec'

local function log(msg)
	io.stderr:write(('[demo] %s\n'):format(msg))
end

local SH = os.getenv('SH') or '/bin/sh'

math.randomseed(os.time())
local SOCK_PATH = ('/tmp/fibers-demo-%d-%d.sock'):format(os.time(), math.random(1, 10^9))

-- External work implemented via sh:
--   * sleep briefly (fall back to 1s if fractional sleep unsupported)
--   * uppercase the input via tr
local WORK_SH = table.concat({
	'sleep 0.2 2>/dev/null || sleep 1',
	'printf "%s" "$1" | tr a-z A-Z',
}, '; ')

local function perform_named_choice(arms)
	return fibers.perform(fibers.named_choice(arms))
end

local function handle_client(scope, stream)
	scope:finally(function()
		stream:close()
	end)

	local jobs = chan.new(16) -- backpressure when workers are busy

	local WORKERS = 2
	for _ = 1, WORKERS do
		fibers.spawn(function()
			while true do
				local job = jobs:get()
				if job == nil then
					return
				end

				-- argv: sh -c <script> sh <arg>
				-- <arg> becomes $1 inside the script.
				local cmd = exec.command(SH, '-c', WORK_SH, 'sh', tostring(job.line))
				cmd:set_stdout('pipe')
				cmd:set_stderr('stdout')

				local out, status, code, sig, err = fibers.perform(cmd:combined_output_op())

				job.reply:put({
					out    = out or '',
					status = status,
					code   = code,
					signal = sig,
					err    = err,
				})
			end
		end)
	end

	fibers.perform(stream:write_string_op('ready\n'))

	while true do
		-- Read a line with timeout and cancellation awareness.
		local which, a, b = perform_named_choice {
			line = stream:read_line_op { max = 4096 },
			timeout = sleep.sleep_op(30.0):wrap(function()
				return nil, 'read timeout'
			end),
			cancelled = scope:not_ok_op():wrap(function(reason)
				return nil, tostring(reason)
			end),
		}

		if which ~= 'line' then
			fibers.perform(stream:write_string_op('error: ' .. tostring(a) .. '\n'))
			return
		end

		local line, rerr = a, b
		if rerr then
			fibers.perform(stream:write_string_op('error: ' .. tostring(rerr) .. '\n'))
			return
		end
		if line == nil then
			return -- EOF
		end

		if line == 'quit' then
			fibers.perform(stream:write_string_op('bye\n'))
			return
		end

		local reply = chan.new(1)
		jobs:put({ line = line, reply = reply })

		local _, resp = perform_named_choice {
			resp = reply:get_op(),
			timeout = sleep.sleep_op(10.0):wrap(function()
				return { err = 'worker timeout' }
			end),
			cancelled = scope:not_ok_op():wrap(function(reason)
				return { err = 'cancelled: ' .. tostring(reason) }
			end),
		}

		if resp.err then
			fibers.perform(stream:write_string_op('error: ' .. tostring(resp.err) .. '\n'))
			return
		end

		local out = resp.out:gsub('\n$', '')
		fibers.perform(stream:write_string_op(out .. '\n'))
	end
end

local function server_loop(scope, path)
	local server, err = socket.listen_unix(path, { ephemeral = true })
	if not server then
		error(err)
	end

	scope:finally(function()
		server:close()
	end)

	log('listening on ' .. path)

	while true do
		local which, a, b = perform_named_choice {
			accept = server:accept_op(),
			cancelled = scope:not_ok_op():wrap(function(reason)
				return nil, tostring(reason)
			end),
		}

		if which ~= 'accept' then
			log('server stopping: ' .. tostring(a))
			return
		end

		local client_stream, aerr = a, b
		if not client_stream then
			log('accept error: ' .. tostring(aerr))
		else
			local client_scope = scope:new_child()
			client_scope:spawn(function(cs)
				handle_client(cs, client_stream)
			end)
		end
	end
end

local function demo_client(scope, path)
	-- Retry briefly in case the server is not yet accepting.
	local stream, err
	for _ = 1, 50 do
		stream, err = socket.connect_unix(path)
		if stream then break end
		sleep.sleep(0.05)
	end
	if not stream then
		error('client connect failed: ' .. tostring(err))
	end

	scope:finally(function()
		stream:close()
	end)

	local ready, rerr = fibers.perform(stream:read_line_op { max = 1024 })
	if rerr or ready ~= 'ready' then
		error('client: unexpected greeting: ' .. tostring(ready) .. ' err=' .. tostring(rerr))
	end

	local inputs = { 'hello', 'world', 'fibers', 'quit' }

	for _, line in ipairs(inputs) do
		fibers.perform(stream:write_string_op(line .. '\n'))
		local resp, e = fibers.perform(stream:read_line_op { max = 8192 })
		if e then error('client read error: ' .. tostring(e)) end
		if resp == nil then error('client: EOF') end
		io.stdout:write(('[client] %s -> %s\n'):format(line, resp))
	end
end

fibers.run(function(scope)
	log('socket path: ' .. SOCK_PATH)
	log('sh: ' .. SH)

	-- Server in a child scope.
	local server_scope = scope:new_child()
	server_scope:spawn(function(ss)
		server_loop(ss, SOCK_PATH)
	end)

	-- Client in a child scope; no pcall. We observe outcome via join_op().
	local client_scope = scope:new_child()
	client_scope:spawn(function(cs)
		demo_client(cs, SOCK_PATH)
	end)

	-- Wait for client completion with a hard timeout for the demo harness.
	local which, a, b = perform_named_choice {
		joined = client_scope:join_op(), -- returns (status, err)
		timeout = sleep.sleep_op(10.0):wrap(function()
			return 'timeout', 'client join timed out'
		end),
	}

	-- Stop the server regardless, then decide what to do about the client outcome.
	server_scope:cancel('demo complete')
	fibers.perform(server_scope:join_op())

	if which == 'timeout' then
		client_scope:cancel('demo timeout')
		fibers.perform(client_scope:join_op())
		error(b)
	end

	local client_status, client_err = a, b
	if client_status ~= 'ok' then
		-- Free to throw: re-raise the client failure after clean shutdown.
		error(client_err or client_status)
	end

	log('demo complete')
end)
