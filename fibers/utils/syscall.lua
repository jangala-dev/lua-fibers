-- Copyright Jangala

local unix = require('unix')
local ffi = require('cffi')
local bit = require('bit32')

local M = { ffi = {} }

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

M.SEEK_CUR = unix.SEEK_CUR
M.SEEK_END = unix.SEEK_END
M.SEEK_SET = unix.SEEK_SET

M.O_ACCMODE = unix.O_ACCMODE
M.O_RDONLY = unix.O_RDONLY
M.O_WRONLY = unix.O_WRONLY
M.O_RDWR = unix.O_RDWR
M.O_CREAT = unix.O_CREAT 
M.O_TRUNC = unix.O_TRUNC 
M.O_APPEND = unix.O_APPEND 
M.O_EXCL = unix.O_EXCL
M.O_NONBLOCK = unix.O_NONBLOCK
M.O_LARGEFILE = ffi.abi('32bit') and 32768 or 0


M.F_GETFL = unix.F_GETFL
M.F_SETFL = unix.F_SETFL

M.EAGAIN = unix.EAGAIN
M.EWOULDBLOCK = unix.EWOULDBLOCK
M.EINTR = unix.EINTR

M.S_IRUSR = 256
M.S_IWUSR = 128
M.S_IXUSR = 64
M.S_IRGRP = 32
M.S_IWGRP = 16
M.S_IXGRP = 8
M.S_IROTH = 4
M.S_IWOTH = 2
M.S_IXOTH = 1

M.STDIN_FILENO = unix.STDIN_FILENO
M.STDOUT_FILENO = unix.STDOUT_FILENO
M.STDERR_FILENO = unix.STDERR_FILENO

M.SIGPIPE = unix.SIGPIPE
M.SIG_IGN = unix.SIG_IGN

M.CLOCK_REALTIME = unix.CLOCK_REALTIME
M.CLOCK_MONOTONIC = unix.CLOCK_MONOTONIC

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

function M.open(path, mode, perm) return unix.open(path, mode, perm) end
function M.close(fd) return unix.close(fd) end
function M.fileno(file) return unix.fileno(file) end
function M.lseek(file, offset, whence) return unix.lseek(file, offset, whence) end
function M.rename(from, to) return unix.rename(from, to) end
function M.fsync(fd) return unix.fsync(fd) end
function M.unlink(path) return unix.unlink(path) end
function M.pipe(mode) return unix.pipe(mode) end
function M.execve(path, argv, env) return unix.execve(path, argv, env) end
function M.exit(status) return unix.exit(status) end
function M.dup2(fd1, fd2, flags) return unix.dup2(fd1, fd2, flags) end
function M.waitpid(pid, options) return unix.waitpid(pid, options) end
-- the fstat function will need changing if we switch to luaposix as its table
-- values have different keys than lunix 
function M.fstat(file, ...) return unix.fstat(file, ...) end
function M.fork() return unix.fork() end
function M.isatty(fd) return unix.isatty(fd) end
function M.sigaction(signo, action, oaction) return unix.sigaction(signo, action, oaction) end
function M.socket(family, socktype, protocol) return unix.socket(family, socktype, protocol) end
function M.bind(file, sockaddr) return unix.bind(file, sockaddr) end
function M.listen(fd, backlog) return unix.listen(fd, backlog) end
function M.strerror(err) return unix.strerror(err) end
function M.fcntl(fd, ...) return unix.fcntl(fd, ...) end
function M.clock_gettime(id) return unix.clock_gettime(id) end
function M.sigtimedwait(set, timeout) return unix.sigtimedwait(set, timeout) end


-------------------------------------------------------------------------------
-- Convenience functions

function M.signal(signum, handler) -- defined in terms of sigaction, see portability notes in Linux man page
    local oldact = M.sigaction(signum, nil, true)
    local ok, err = M.sigaction(signum, handler, oldact)
    if not ok then return nil, err end
    local num = tonumber(t.intptr(oldact.handler))
    local ret = sigret[num]
    if ret then return ret end -- return eg "IGN", "DFL" not a function pointer
    return oldact.handler
end


function M.set_nonblock(file)
    local fd = M.fileno(file)
	local flags = assert(M.fcntl(fd, M.F_GETFL))
	assert( M.fcntl(fd, M.F_SETFL, bor(flags, M.O_NONBLOCK)))
end

function M.set_block(file)
    local fd = M.fileno(file)
	local flags = assert(M.fcntl(fd, M.F_GETFL))
	assert( M.fcntl(fd, M.F_SETFL, band(flags, bnot(M.O_NONBLOCK))))
end

function M.monotime()
    return M.clock_gettime(M.CLOCK_MONOTONIC)
end

function M.realtime()
    return M.clock_gettime(M.CLOCK_REALTIME)
end

function M.floatsleep(sec)
    if sec > 0 then
        local _, _, errno = M.sigtimedwait("", sec)
        assert(errno == M.EAGAIN) -- to make sure sleep wasn't interrupted
    end
end


-------------------------------------------------------------------------------
-- FFI C structure functions (for efficiency)

M.ffi.typeof = ffi.typeof
M.ffi.sizeof = ffi.sizeof

ffi.cdef [[
    size_t write(int fildes, const void *buf, size_t nbytes);
    size_t read(int fildes, void *buf, size_t nbytes);
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
