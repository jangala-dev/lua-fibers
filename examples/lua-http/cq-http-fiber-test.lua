-- inspired by https://gist.github.com/daurnimator/f1c7965b47a5658b88300403645541aa

local fiber = require "fibers.fiber"
local op = require "fibers.op"
local file = require "fibers.file"
local sleep = require "fibers.sleep"
local cqueues = require "cqueues"
local stdio = require "posix.stdio"

local old_step; old_step = cqueues.interpose("step", function(self, timeout)
	if cqueues.running() then
		fiber.yield()
		return old_step(self, timeout)
	else
		local t = self:timeout() or math.huge
		if timeout then
			t = math.min(t, timeout)
		end
        local events = self:events()
        -- messy
        if events == 'r' then
            file.fd_readable_op(self:pollfd()):perform()
        elseif events == 'w' then
            file.fd_writable_op(self:pollfd()):perform()
        elseif events == 'rw' then
            op.choice(
                file.fd_readable_op(self:pollfd()),
                file.fd_writable_op(self:pollfd())
            ):perform()
        end
		return old_step(self, 0.0)
	end
end)

local http_headers = require "http.headers"
local http_server = require "http.server"
local http_util = require "http.util"

local function reply(myserver, stream) -- luacheck: ignore 212
	-- Read in headers
	local req_headers = assert(stream:get_headers())
	local req_method = req_headers:get ":method"

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

local myserver = assert(http_server.listen {
	host = "127.0.0.1";
	port = 8000;
	onstream = reply;
	onerror = function(self, context, op, err)
		local msg = op .. " on " .. tostring(context) .. " failed"
		if err then
				msg = msg .. ": " .. tostring(err)
		end
		assert(io.stderr:write(msg, "\n"))
	end;
})
-- Override :add_stream to call onstream in a new fiber (instead of new cqueues coroutine)
function myserver:add_stream(stream)
	fiber.spawn(function()
		fiber.yield() -- want to be called from main loop; not from :add_stream callee
		local ok, err = http_util.yieldable_pcall(self.onstream, self, stream)
		stream:shutdown()
		if not ok then
			self:onerror()(self, stream, "onstream", err)
		end
	end)
end

-- Run server in its own lua-fiber
fiber.spawn(function()
	assert(myserver:loop())
end)

-- Start another fiber that just prints+sleeps in a loop to show off non-blocking-ness of http server
fiber.spawn(function()
	for i=1, 1e6 do
		print("heartbeat ", i)
		sleep.sleep(1.1)
	end
end)

-- And one more to show multiple epolls in action
fiber.spawn(function()
    local fd = assert(io.popen('while true; do echo "non-http fd input received!"; sleep 5; done'))
    while true do
        file.fd_readable_op(stdio.fileno(fd)):perform()
        local line = fd:read("*l")
        if line then 
            print(line)
        else
            fd:close()
            break
        end
    end
end)

require('fibers.file').install_poll_io_handler()

fiber.main()