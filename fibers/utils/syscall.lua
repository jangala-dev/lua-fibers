-- Copyright Jangala

local p_fcntl = require 'posix.fcntl'
local p_unistd = require 'posix.unistd'
local p_stdio = require 'posix.stdio'
local p_wait = require 'posix.sys.wait'
local p_stat = require 'posix.sys.stat'
local p_signal = require 'posix.signal'
local p_socket = require 'posix.sys.socket'
local p_errno = require 'posix.errno'
local p_time = require 'posix.time'
local bit = rawget(_G, "bit") or require 'bit32'

local M = { ffi = {} } -- used this module format due to large number of exported functions

--detect LuaJIT
M.is_LuaJIT = rawget(_G, "jit") and true or false

local ffi = M.is_LuaJIT and require 'ffi' or require 'cffi'
ffi.tonumber = ffi.tonumber or tonumber
ffi.type = ffi.type or type


-------------------------------------------------------------------------------
-- Compatibility functions

table.pack = table.pack or function(...)
    return { n = select("#", ...), ... }
end


-------------------------------------------------------------------------------
-- Local functions (for efficiency)

local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift


-------------------------------------------------------------------------------
-- Syscall constants

M.SEEK_CUR = p_unistd.SEEK_CUR
M.SEEK_END = p_unistd.SEEK_END
M.SEEK_SET = p_unistd.SEEK_SET

M.O_ACCMODE = 3
M.O_RDONLY = p_fcntl.O_RDONLY
M.O_WRONLY = p_fcntl.O_WRONLY
M.O_RDWR = p_fcntl.O_RDWR
M.O_CREAT = p_fcntl.O_CREAT
M.O_TRUNC = p_fcntl.O_TRUNC
M.O_APPEND = p_fcntl.O_APPEND
M.O_EXCL = p_fcntl.O_EXCL
M.O_NONBLOCK = p_fcntl.O_NONBLOCK
M.O_LARGEFILE = ffi.abi('32bit') and 32768 or 0

M.F_GETFL = p_fcntl.F_GETFL
M.F_SETFL = p_fcntl.F_SETFL

M.EAGAIN = p_errno.EAGAIN
M.EWOULDBLOCK = p_errno.EWOULDBLOCK
M.EINTR = p_errno.EINTR
M.EINPROGRESS = p_errno.EINPROGRESS

M.S_IRUSR = p_stat.S_IRUSR
M.S_IWUSR = p_stat.S_IWUSR
M.S_IXUSR = p_stat.S_IXUSR
M.S_IRGRP = p_stat.S_IRGRP
M.S_IWGRP = p_stat.S_IWGRP
M.S_IXGRP = p_stat.S_IXGRP
M.S_IROTH = p_stat.S_IROTH
M.S_IWOTH = p_stat.S_IWOTH
M.S_IXOTH = p_stat.S_IXOTH

M.STDIN_FILENO = p_unistd.STDIN_FILENO
M.STDOUT_FILENO = p_unistd.STDOUT_FILENO
M.STDERR_FILENO = p_unistd.STDERR_FILENO

M.SIGPIPE = p_signal.SIGPIPE
M.SIG_IGN = p_signal.SIG_IGN

M.CLOCK_REALTIME = p_time.CLOCK_REALTIME
M.CLOCK_MONOTONIC = p_time.CLOCK_MONOTONIC

M.AF_INET = p_socket.AF_INET
M.AF_INET6 = p_socket.AF_INET6
M.AF_NETLINK = p_socket.AF_NETLINK
M.AF_PACKET = p_socket.AF_PACKET
M.AF_UNIX = p_socket.AF_UNIX
M.AF_UNSPEC = p_socket.AF_UNSPEC
M.SO_ERROR = p_socket.SO_ERROR
M.SOCK_DGRAM = p_socket.SOCK_DGRAM
M.SOCK_RAW = p_socket.SOCK_RAW
M.SOCK_STREAM = p_socket.SOCK_STREAM
M.SOL_SOCKET = p_socket.SOL_SOCKET
M.SOMAXCONN = p_socket.SOMAXCONN

M.WNOHANG = p_wait.WNOHANG

---- Would be cleaner to implement epoll using our cffi-lua dependency rather
---- than carrying on using the afghanistanyn epoll dependency
-- M.EPOLLIN = 0x001
-- M.EPOLLPRI = 0x002
-- M.EPOLLOUT = 0x004
-- M.EPOLLRDNORM = 0x040
-- M.EPOLLRDBAND = 0x080
-- M.EPOLLWRNORM = 0x100
-- M.EPOLLWRBAND = 0x200
-- M.EPOLLMSG = 0x400
-- M.EPOLLERR = 0x008
-- M.EPOLLHUP = 0x010
-- M.EPOLLRDHUP = 0x2000
-- M.EPOLLONESHOT = lshift(1, 30)
-- M.EPOLLET = lshift(1, 31)

-------------------------------------------------------------------------------
-- Luafied stdlib syscalls

function M.fcntl(fd, ...) return p_fcntl.fcntl(fd, ...) end
function M.open(path, mode, perm) return p_fcntl.open(path, mode, perm) end

function M.strerror(err) return p_errno.errno(err) end

function M.fstat(file, ...) return p_stat.fstat(file, ...) end

function M.signal(signum, handler) return p_signal.signal(signum, handler) end

function M.accept(fd) return p_socket.accept(fd) end
function M.bind(file, sockaddr) return p_socket.bind(file, sockaddr) end
function M.connect(fd, addr) return p_socket.connect(fd, addr) end
function M.getpeername(sockfd) return p_socket.getpeername(sockfd) end
function M.getsockname(sockfd) return p_socket.getsockname(sockfd) end
function M.getsockopt(fd, level, name) return p_socket.getsockopt(fd, level, name) end
function M.listen(fd, backlog) return p_socket.listen(fd, backlog or M.SOMAXCONN) end
function M.socket(family, socktype, protocol) return p_socket.socket(family, socktype, protocol) end

function M.fileno(file) return p_stdio.fileno(file) end
function M.rename(from, to) return p_stdio.rename(from, to) end

function M.clock_gettime(id) return p_time.clock_gettime(id) end

function M.close(fd) return p_unistd.close(fd) end
function M.dup2(fd1, fd2) return p_unistd.dup2(fd1, fd2) end
function M.execp(path, argt) return p_unistd.execp(path, argt) end
function M.execve(path, argv, _) return p_unistd.exec(path, argv) end
function M.fork() return p_unistd.fork() end
function M.fsync(fd) return p_unistd.fsync(fd) end
function M.isatty(fd) return p_unistd.isatty(fd) end
function M.lseek(file, offset, whence) return p_unistd.lseek(file, offset, whence) end
function M.pipe() return p_unistd.pipe() end
function M.read(fd, count) return p_unistd.read(fd, count) end
function M.unlink(path) return p_unistd.unlink(path) end
function M.write(fd, buf) return p_unistd.write(fd, buf) end

function M.waitpid(pid, options) return p_wait.wait(pid, options) end

function M.exit(status) return os.exit(status) end

-------------------------------------------------------------------------------
-- Convenience functions

function M.set_nonblock(fd)
	local flags = assert(M.fcntl(fd, M.F_GETFL))
	assert( M.fcntl(fd, M.F_SETFL, bor(flags, M.O_NONBLOCK)))
end

function M.set_block(fd)
	local flags = assert(M.fcntl(fd, M.F_GETFL))
	assert( M.fcntl(fd, M.F_SETFL, band(flags, bnot(M.O_NONBLOCK))))
end

function M.monotime()
    local time = M.clock_gettime(M.CLOCK_MONOTONIC)
    return time.tv_sec + time.tv_nsec/1e9
end

function M.realtime()
    local time = M.clock_gettime(M.CLOCK_REALTIME)
    return time.tv_sec + time.tv_nsec/1e9
end

function M.floatsleep(t)
    local sec = t - t%1
    local nsec = t%1 * 1e9
    local _, _, _, remaining = p_time.nanosleep({tv_sec=sec, tv_nsec=nsec})
    while remaining do
        p_time.nanosleep(remaining)
    end
end

------------------------------------
-- epoll

ffi.cdef[[
    typedef struct epoll_event {
        uint32_t events;
        uint64_t data;
    } epoll_event;

    int epoll_create(int size);
    int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
    int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);

    int fcntl(int fd, int cmd, ...);
    int close(int fd);
    char *strerror(int errnum);
]]

local O_NONBLOCK = 0x800
local F_SETFL = 4

M.EPOLLIN = 0x001
M.EPOLLPRI = 0x002
M.EPOLLOUT = 0x004
M.EPOLLRDNORM = 0x040
M.EPOLLRDBAND = 0x080
M.EPOLLWRNORM = 0x100
M.EPOLLWRBAND = 0x200
M.EPOLLMSG = 0x400
M.EPOLLERR = 0x008
M.EPOLLHUP = 0x010
M.EPOLLRDHUP = 0x2000
M.EPOLLONESHOT =  bit.lshift(1, 30)
M.EPOLLET = bit.lshift(1, 30)


local EPOLL_CTL_ADD = 1
local EPOLL_CTL_DEL = 2
local EPOLL_CTL_MOD = 3


-- Returns an epoll file descriptor.
function M.epoll_create()
    local fd = ffi.C.epoll_create(1)
    if fd == -1 then
        return nil, ffi.string(ffi.C.strerror(ffi.errno()))
    end
    return fd
end

-- Register eventmask of a file descriptor onto epoll file descriptor.
function M.epoll_register(epfd, fd, eventmask)
    local event = ffi.new("struct epoll_event")
    event.events = eventmask
    event.data = fd
    local res = ffi.C.epoll_ctl(epfd, EPOLL_CTL_ADD, fd, event)
    if res == -1 then
        return false, ffi.string(ffi.C.strerror(ffi.errno()))
    end
    return true
end

-- Modify eventmask of a file descriptor.
function M.epoll_modify(epfd, fd, eventmask)
    local event = ffi.new("struct epoll_event")
    event.events = eventmask
    event.data = fd
    local res = ffi.C.epoll_ctl(epfd, EPOLL_CTL_MOD, fd, event)
    if res == -1 then
        return false, ffi.string(ffi.C.strerror(ffi.errno()))
    end
    return true
end

-- Remove a registered file descriptor from the epoll file descriptor.
function M.epoll_unregister(epfd, fd)
    local event = ffi.new("struct epoll_event") -- event can be null when removing
    local res = ffi.C.epoll_ctl(epfd, EPOLL_CTL_DEL, fd, event)
    if res == -1 then
        return false, ffi.string(ffi.C.strerror(ffi.errno()))
    end
    return true
end

-- Wait for events.
function M.epoll_wait(epfd, timeout, max_events)
    local events = ffi.new("struct epoll_event[?]", max_events)
    local num_events = ffi.C.epoll_wait(epfd, events, max_events, timeout)
    if num_events == -1 then
        return nil, ffi.string(ffi.C.strerror(ffi.errno()))
    end

    -- Create a table to hold the resulting events
    local res = {}

    -- Loop over the events, inserting them into the table with their fd as the key
    for i = 0, num_events - 1 do
        local fd = assert(ffi.tonumber(events[i].data))
        local event = assert(ffi.tonumber(events[i].events))
        res[fd] = event
    end

    return res, num_events
end

-- Close epoll file descriptor.
function M.epoll_close(epfd)
    local res = ffi.C.close(epfd)
    if res == -1 then
        return false, ffi.string(ffi.C.strerror(ffi.errno()))
    end
    return true
end



-------------------------------------------------------------------------------
-- FFI C structure functions (for efficiency)

M.ffi.typeof = ffi.typeof
M.ffi.sizeof = ffi.sizeof

ffi.cdef [[
    ssize_t write(int fildes, const void *buf, size_t nbytes);
    ssize_t read(int fildes, void *buf, size_t nbytes);
    int memcmp(const void *s1, const void *s2, size_t n);
]]

local ffi_write = ffi.C.write
local ffi_read = ffi.C.read
local memcmp = ffi.C.memcmp

local function wrap_error(retval)
    if retval >= 0 then
        return retval
    else
        local errno = ffi.errno()
        return nil, M.strerror(errno), errno
    end
end

function M.ffi.write(fildes, buf, nbytes)
    local retval = ffi.tonumber(ffi_write(fildes, buf, nbytes))
    return wrap_error(retval)
end

function M.ffi.read(fildes, buf, nbytes)
    local retval = ffi.tonumber(ffi_read(fildes, buf, nbytes))
    return wrap_error(retval)
end

function M.ffi.memcmp(obj1, obj2, nbytes)
    return ffi.tonumber(memcmp(obj1, obj2, nbytes))
end

return M
