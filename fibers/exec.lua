-- fibers/exec.lua
-- Provides facilities for executing external commands asynchronously using fibers.
local file = require 'fibers.stream.file'
local pollio = require 'fibers.pollio'
local fiber = require 'fibers.fiber'
local waitgroup = require 'fibers.waitgroup'
local string_buffer = require 'fibers.utils.string_buffer'
local sc = require 'fibers.utils.syscall'

local exec = {}

-- Define the command type
local Cmd = {}
Cmd.__index = Cmd -- set metatable

--- Constructor for Cmd.
-- @param name The name or path of the command to execute.
-- @param ... Additional arguments for the command.
-- @return A new Cmd instance.
function exec.command(name, ...)
    local self = setmetatable({}, Cmd)
    self.path = name
    self.args = {...}
    self.child_io_files = {}
    self.parent_io_pipes = {}
    self.external_io_pipes = {}
    self.pipe_wg = waitgroup.new()
    return self
end

--- Sets the command to launch with a different pgid.
-- @param status True if diff pgid desired.
function Cmd:setpgid(status)
    self._setpgid = status
end

--- Launches the command.
-- @param path The path to the executable.
-- @param argt Table of arguments.
-- @return pid, cmd_streams, result_channel, error
function Cmd:launch(path, argt)
    -- Check if the executable exists and is executable
    local status, errstr, _ = sc.access(path, "x")
    if not status then return nil, nil, nil, errstr end

    local in_r, in_w = assert(sc.pipe())
    local out_r, out_w = assert(sc.pipe())
    local err_r, err_w = assert(sc.pipe())
    local pid = assert(sc.fork())
    if pid == 0 then -- child
        if self._setpgid then
            local result, err_msg = sc.setpid('p', 0, 0)
            assert(result==0, err_msg)
        end
        for _, v in ipairs(self.external_io_pipes) do v:close() end
        for _, v in ipairs(self.parent_io_pipes) do v:close() end
        sc.close(in_w); sc.dup2(in_r, sc.STDIN_FILENO); sc.close(in_r)
        sc.close(out_r); sc.dup2(out_w, sc.STDOUT_FILENO); sc.close(out_w)
        sc.close(err_r); sc.dup2(err_w, sc.STDERR_FILENO); sc.close(err_w)
        local _, err, errno = sc.exec(path, argt) -- will not return unless unsuccessful
        if err then
            io.stderr:write(err .. "\n")
            sc.exit(errno) -- exit with non-zero status
        end
    end
    -- parent
    local pidfd, err = sc.pidfd_open(pid, 0)
    assert(pidfd, err)
    sc.close(in_r); sc.close(out_w); sc.close(err_w)
    local ret_streams = {
        stdin = file.fdopen(in_w):setvbuf('no'),
        stdout = file.fdopen(out_r),
        stderr = file.fdopen(err_r),
    }
    return pid, ret_streams, pidfd, nil
end

--- Gets the combined output of stdout and stderr.
-- @return The combined output and any error.
function Cmd:combined_output()
    local buf = string_buffer.new()
    self.stdout, self.stderr = buf, buf
    local err = self:run()
    if err then return buf:read(), err end
    return buf:read(), nil
end

--- Gets the output of stdout.
-- @return The output and any error.
function Cmd:output()
    local buf = string_buffer.new()
    self.stdout = buf
    local err = self:run()
    if err then return buf:read(), err end
    return buf:read(), nil
end

function Cmd:run()
    local err = self:start()
    if err then
        return err
    end
    return self:wait()
end

--- Starts the command.
-- @return Any error.
function Cmd:start()
    if self.process then return nil, "process already started" end

    local function close_parent_io()
        for _, fd in ipairs(self.parent_io_pipes) do fd:close() end
    end

    local function close_child_io()
        for _, fd in ipairs(self.child_io_files) do fd:close() end
    end

    local function error_return(err)
        close_child_io(); close_parent_io()
        return err
    end

    local executablePath
    -- Check if a path is provided
    if self.path:find("/") then
        executablePath = self.path
    else
        -- Search for the executable in the PATH
        for dir in os.getenv("PATH"):gmatch("[^:]+") do
            local fullPath = dir .. "/" .. self.path
            if sc.access(fullPath, "x") then
                executablePath = fullPath
                break
            end
        end
        if not executablePath then return error_return('"'..self.path..'": executable file not found in $PATH') end
    end

    local pid, cmd_streams, pidfd, err = self:launch(executablePath, self.args)
    if not pid then
        return error_return(err)
    end

    close_child_io()

    self.process = pid
    self.pidfd = pidfd
    self.cmd_streams = cmd_streams

    local io_types = {"stdin", "stdout", "stderr"}

    for _, v in ipairs(io_types) do
        self.pipe_wg:add(1)
        if not self[v] then
            self[v] = assert(file.open("/dev/null", v == "stdin" and "r" or "w"))
            table.insert(self.parent_io_pipes, self[v])
        end
        local input = v=="stdin" and self.stdin or self.cmd_streams[v]
        local output = v=="stdin" and self.cmd_streams.stdin or self[v]
        fiber.spawn(function()
            while true do
                local received = input:read_some_chars()
                output:write(received)
                if not received then break end
            end
            if output.close then output:close() end
            if input.close then input:close() end
            self.pipe_wg:done()
        end)
    end
end

--- Kills the command.
-- @return Any error.
function Cmd:kill()
    if not self.process then return "process not started" end
    if self.process_state then return "process has already completed" end

    local res, err, errno = sc.kill(self._setpgid and -self.process or self.process)

    assert(res==0 or errno==sc.ESRCH, err)
end

--- Sets up a pipe for the given IO type.
-- @param io_type The type of IO ("stdin", "stdout", or "stderr").
-- @return The pipe or an error.
local function setup_pipe(self, io_type)
    if self[io_type] then return nil, io_type .. " pipe already created" end
    if self.process then return nil, io_type .. "_pipe after process started" end

    local rd, wr = file.pipe()
    wr:setvbuf('no')
    if io_type == "stdin" then
        self.stdin = rd
    else
        self[io_type] = wr
    end

    table.insert(self.parent_io_pipes, (io_type == "stdin" and rd) or wr)
    table.insert(self.external_io_pipes, (io_type == "stdin" and wr) or rd)

    return (io_type == "stdin" and wr) or rd, nil
end

--- Creates a pipe for stdout. Call `:close()` when finished.
-- @return The stdout pipe or an error.
function Cmd:stdout_pipe()
    return setup_pipe(self, "stdout")
end

--- Creates a pipe for stderr. Call `:close()` when finished.
-- @return The stderr pipe or an error.
function Cmd:stderr_pipe()
    return setup_pipe(self, "stderr")
end

--- Creates a pipe for stdin. Call `:close()` when finished.
-- @return The stdin pipe or an error.
function Cmd:stdin_pipe()
    return setup_pipe(self, "stdin")
end


--- Waits for the command to complete.
-- @return The completion status or an error.
function Cmd:wait()
    pollio.fd_readable_op(self.pidfd):perform()
    self.pipe_wg:wait()
    local _, _, status = sc.waitpid(self.process)
    sc.close(self.pidfd)
    self.process_state = status
    if status ~= 0 then return status end
end

return exec
