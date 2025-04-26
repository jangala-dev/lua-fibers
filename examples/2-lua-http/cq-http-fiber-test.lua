-- inspired by https://gist.github.com/daurnimator/f1c7965b47a5658b88300403645541aa

package.path="./?.lua;/usr/share/lua/?.lua;/usr/share/lua/?/init.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"
	.. package.path
package.path = "../../?.lua;../?.lua;" .. package.path

require "fibers_cqueues"
local fiber = require "fibers.fiber"
local pollio = require "fibers.pollio"
local sleep = require "fibers.sleep"
local exec = require "fibers.exec"
local websocket = require "http.websocket"

print("installing poll handler")
pollio.install_poll_io_handler()

local http_headers = require "http.headers"
local http_server = require "http.server"
local http_util = require "http.util"

local function reply(_, stream) -- luacheck: ignore 212
	-- Read in headers
	local req_headers = assert(stream:get_headers())
	local req_method = req_headers:get(":method")

	-- Log request to stdout
	assert(io.stdout:write(string.format('[%s] "%s %s HTTP/%g"  "%s" "%s"\n',
		os.date("%d/%b/%Y:%H:%M:%S %z"),
		req_method or "",
		req_headers:get(":path") or "",
		stream.connection.version,
		req_headers:get("referer") or "-",
		req_headers:get("user-agent") or "-"
	)))

	-- Build response headers
	local res_headers = http_headers.new()
	res_headers:append(":status", "200")
	res_headers:append("content-type", "text/plain")
	-- Send headers to client; end the stream immediately if this was a HEAD request
	assert(stream:write_headers(res_headers, req_method == "HEAD"))
	if req_method ~= "HEAD" then
		-- Send body, ending the stream
		assert(stream:write_chunk("Hello world!\n"..os.date().."\n", true))
	end
end

print("defining server")
local myserver = assert(http_server.listen {
	host = "127.0.0.1";
	port = 8000;
	onstream = reply;
	onerror = function(_, context, operation, err)
		local msg = operation .. " on " .. tostring(context) .. " failed"
		if err then
			msg = msg .. ": " .. tostring(err)
		end
		assert(io.stderr:write(msg, "\n"))
	end;
})

-- Override :add_stream to call onstream in a new fiber (instead of new cqueues coroutine)
print("overriding server's 'add_stream' method")
function myserver:add_stream(stream)
	fiber.spawn(function()
		local ok, err = http_util.yieldable_pcall(self.onstream, self, stream)
		stream:shutdown()
		if not ok then
			self:onerror()(self, stream, "onstream", err)
		end
	end)
end

-- Run server in its own lua-fiber
print("spawning server")
fiber.spawn(function()
	print("starting server")
	assert(myserver:loop())
end)

-- Start another fiber that just prints+sleeps in a loop to show off non-blocking-ness of http server
print("spawning heartbeat")
fiber.spawn(function()
	print("starting heartbeat")
	while true do
		print("slow heartbeat")
		sleep.sleep(1)
	end
end)

-- And one more to show multiple epolls in action
print("spawning popen fiber")
fiber.spawn(function()
	local cmd = exec.command('sh', '-c', 'while true; do echo "non-http fd input received!"; sleep 5; done')
	local stdout_pipe = assert(cmd:stdout_pipe())
	local err = cmd:start()
	if err then error(err) end
	while true do
	   local received = stdout_pipe:read_line()
	   print(received)
	end
end)

-- Why not throw in some websockets?
fiber.spawn(function()
	local ws = websocket.new_from_uri("wss://ws.kraken.com")
	assert(ws:connect())
	local subscribe_message = [[ { "event": "subscribe", "subscription": { "name": "ticker" }, "pair": ["XBT/USD"]} ]]
	assert(ws:send(subscribe_message))
	for i = 1, 1000 do
		local message = assert(ws:receive())
		if #message ~= 21 then print(message) end
	end

	assert(ws:close())
end)

print("starting fibers")
fiber.main()
