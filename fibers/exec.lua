-- fibers/exec.lua
-- Provides facilities for executing external commands asynchronously using fibers.
local file = require 'fibers.stream.file'
local pollio = require 'fibers.pollio'
local fiber = require 'fibers.fiber'
local queue = require 'fibers.queue'
local string_buffer = require 'fibers.utils.string_buffer'
local sc = require 'fibers.utils.syscall'

local active_commands = {}

--[[ 
we can replace this centralised risky feeling signal based watcher with the new 
Linux 5.3 call `pidfd_open` which returns an fd that becomes readable when the 
process has exited. We can get the relevant process info from /proc/[PID]/stat. 
then `wait`ing. the key advantage is that this approach requires no messing 
around with a centralised signal handler and each cmd instance can handle its own 
process.
]]
-- Watcher for child process signals.
local function signalfd_watcher()
    fiber.spawn(function ()
        pollio.install_poll_io_handler()
    
        local SIG_BLOCK = sc.SIG_BLOCK
        local SIGCHLD = sc.SIGCHLD
        local mask = sc.new_sigset()
        
        assert(sc.sigemptyset(mask))
        assert(sc.sigaddset(mask, SIGCHLD))
        assert(sc.pthread_sigmask(SIG_BLOCK, mask, nil))
        
        local signal_fd = assert(sc.signalfd(-1, mask, 0))
        
        if signal_fd == -1 then
            error("signalfd error")
        end
        
        local signal_fd_stream = file.fdopen(signal_fd)
    
        while true do
            local fdsi = sc.new_fdsi()
            signal_fd_stream:read_struct(fdsi, "signalfd_siginfo")
            if fdsi.ssi_pid then
                active_commands[fdsi.ssi_pid]:put(fdsi)
            end
        end
    end)
end

signalfd_watcher()

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
    local result_channel = queue.new(1) -- buffered channel len 1
    local pid = assert(sc.fork())
    if pid == 0 then -- child
        if self._setpgid then
            local child_pid = sc.getpid()  -- Get child's PID
            local result, err_msg = sc.setpid('p', child_pid, child_pid)
            assert(not result, err_msg)
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
    active_commands[pid] = result_channel
    assert(active_commands[pid])
    sc.close(in_r); sc.close(out_w); sc.close(err_w)
    local ret_streams = {
        stdin = file.fdopen(in_w):setvbuf('no'),
        stdout = file.fdopen(out_r),
        stderr = file.fdopen(err_r),
    }
    return pid, ret_streams, result_channel, nil
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

    local pid, cmd_streams, result_channel, err = self:launch(executablePath, self.args)
    if not pid then
        return error_return(err)
    end

    close_child_io()

    self.process = pid
    self.result_channel = result_channel
    self.cmd_streams = cmd_streams

    local io_types = {"stdin", "stdout", "stderr"}

    for _, v in ipairs(io_types) do
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
        end)
    end
end

--- Starts the command.
-- @return Any error.
function Cmd:kill()
    if not self.process then return "process not started" end
    if self.process_state then return "process has already completed" end

    local pid = not self.setpgid and self.process or -self.process
    local res, err
    
    if not self.setpgid then
        res, err = sc.kill(self.process)
    else
        res, err = sc.killpg(self.process)
    end

    if not res then
        return err
    end
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
    if self.process_state then
        return "Command has already completed"
    end
    self.process_state = self.result_channel:get()
    active_commands[self.process] = nil
    sc.waitpid(self.process)
    if self.process_state.ssi_status == 0 then
        return nil
    else
        return self.process_state.ssi_status
    end
end

return exec
