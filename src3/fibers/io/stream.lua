-- fibers/io/stream.lua
--
-- Pulse-only stream:
--   * Stream-owned LinearBuf for RX (append in poll, consume in commit)
--   * No write buffering (write ops drive syscalls directly)
--   * No waitsets; on would-block, arm poller watch for ctx.waker

local bytes   = require 'fibers.utils.bytes'
local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'
local List    = require 'fibers.utils.intrusive_list'

local unpack = rawget(table, 'unpack') or _G.unpack

local LinearBuf     = bytes.LinearBuf
local new_primitive = op.new_primitive

local Stream = {}
Stream.__index = Stream

local DEFAULT_READ_CHUNK = 4096

----------------------------------------------------------------------
-- Small intrusive list for lane waiters (nodes owned by ops)
----------------------------------------------------------------------

local function pop_active(list)
    while true do
        local n = list:pop_head_node()
        if not n then return nil end
        if n.waker then return n end
    end
end

local function wake_one(list)
    local n = pop_active(list)
    if n and n.waker then
        local w = n.waker
        n.waker = nil
        w:signal()
    end
end

local function wake_all(list)
    while true do
        local n = list:pop_head_node()
        if not n then break end
        local w = n.waker
        n.waker = nil
        if w then w:signal() end
    end
end

----------------------------------------------------------------------
-- Construction / lifecycle
----------------------------------------------------------------------

---@param io_backend table
---@param readable? boolean
---@param writable? boolean
---@param _bufsize? integer  -- ignored (kept for signature compatibility)
local function open(io_backend, readable, writable, _bufsize)
    local s = setmetatable({
        io = io_backend,

        rx = (readable ~= false) and LinearBuf.new() or nil,

        _closed = false,
        _eof    = false,

        _sticky_rerr = nil,
        _sticky_werr = nil,

        _rd_owner = nil,
        _wr_owner = nil,

        _rd_waiters = List.new(),
        _wr_waiters = List.new(),
    }, Stream)

    return s
end

local function is_stream(x)
    return type(x) == 'table' and getmetatable(x) == Stream
end

function Stream:fileno()
    local io = self.io
    return io and io.fileno and io:fileno() or nil
end

function Stream:terminate(_)
    if self._closed then return end
    self._closed = true

    -- Wake any active lane owners so blocked ops can observe closure.
    local ro = self._rd_owner
    if ro and ro.waker then ro.waker:signal() end
    local wo = self._wr_owner
    if wo and wo.waker then wo.waker:signal() end

    -- Wake any lane waiters so blocked ops can observe closure.
    wake_all(self._rd_waiters)
    wake_all(self._wr_waiters)

    local io = self.io
    self.io = nil

    if io and io.close then
        pcall(function () io:close() end)
    end
end

----------------------------------------------------------------------
-- Lane helpers
----------------------------------------------------------------------

local function lane_acquire(stream, field, owner, waiters, node, waker)
    local cur = stream[field]
    if cur == nil then
        -- Was queued waiting for the lane: drop node before owning.
        if node and node.inq then
            waiters:unlink(node)
            node.waker = nil
        end
        stream[field] = owner
        return true
    end
    if cur == owner then
        return true
    end

    node.waker = waker
    waiters:push(node)
    return false
end

local function lane_release(stream, field, owner, waiters, node)
    if node and node.inq then
        waiters:unlink(node)
        node.waker = nil
    end
    if stream[field] == owner then
        stream[field] = nil
        wake_one(waiters)
    end
end

----------------------------------------------------------------------
-- Poller watch helpers (per-op, one-shot)
----------------------------------------------------------------------

local function watch_arm(self, ctx, dir)
    local s  = self.stream
    local fd = s:fileno()
    if not fd then
        error('stream has no fileno() for poller integration', 0)
    end

    if self.watch then
        runtime.poller_cancel(self.watch)
        self.watch = nil
    end

    self.watch = runtime.poller_watch(fd, dir, ctx.waker)
end

local function watch_cancel(self)
    if self.watch then
        runtime.poller_cancel(self.watch)
        self.watch = nil
    end
end

----------------------------------------------------------------------
-- Read helpers
----------------------------------------------------------------------

local function read_ready(stream, kind, arg, term, keep_term)
    local rx    = stream.rx
    local avail = rx:read_avail()

    local terminal_err = stream._sticky_rerr
    local terminal = terminal_err ~= nil or stream._eof or stream._closed or (stream.io == nil)

    if kind == 'some' then
        if avail > 0 then
            local n = arg
            if n > avail then n = avail end
            return true, rx:peek(n), terminal_err
        end
        if terminal then return true, nil, terminal_err end
        return false
    end

    if kind == 'exactly' then
        local n = arg
        if avail >= n then return true, rx:peek(n), nil end
        if terminal then return true, nil, terminal_err or 'short read' end
        return false
    end

    if kind == 'line' then
        local off = rx:find(term)
        if off ~= nil then
            local take = off + #term
            local s = rx:peek(take)
            if not keep_term and #term > 0 then
                s = s:sub(1, #s - #term)
            end
            return true, s, terminal_err
        end
        if terminal then
            if avail == 0 then return true, nil, terminal_err end
            return true, rx:peek(avail), terminal_err
        end
        return false
    end

    -- kind == 'all'
    if terminal then
        if avail == 0 then return true, '', terminal_err end
        return true, rx:peek(avail), terminal_err
    end
    return false
end

local function read_consume(stream, kind, arg, term, keep_term)
    local rx    = stream.rx
    local avail = rx:read_avail()

    local terminal_err = stream._sticky_rerr
    local terminal = terminal_err ~= nil or stream._eof or stream._closed or (stream.io == nil)

    if kind == 'some' then
        if avail == 0 then return nil, terminal_err end
        local n = arg
        if n > avail then n = avail end
        return rx:take(n), terminal_err
    end

    if kind == 'exactly' then
        local n = arg
        if avail >= n then return rx:take(n), nil end
        return nil, terminal_err or 'short read'
    end

    if kind == 'line' then
        local off = rx:find(term)
        if off ~= nil then
            local take = off + #term
            local s = rx:take(take)
            if not keep_term and #term > 0 then
                s = s:sub(1, #s - #term)
            end
            return s, terminal_err
        end
        if terminal then
            if avail == 0 then return nil, terminal_err end
            return rx:take(avail), terminal_err
        end
        return nil, 'not ready'
    end

    -- all
    if avail == 0 then return '', terminal_err end
    return rx:take(avail), terminal_err
end

----------------------------------------------------------------------
-- Read op (primitive, shared poll/commit/rollback)
----------------------------------------------------------------------

local function read_poll(self, ctx, out)
    if self.done then
        if out then
            out.n = 2
            out[1], out[2] = self.r1, self.r2
        end
        return true
    end

    local stream = self.stream

    if self.waker and self.waker ~= ctx.waker then
        error('stream read op used from a different fibre', 0)
    end
    self.waker = ctx.waker

    if not lane_acquire(stream, '_rd_owner', self, stream._rd_waiters, self.lane_node, ctx.waker) then
        return false
    end

    local kind = self.kind
    local arg  = self.arg
    local term = self.term
    local keep = self.keep

    while true do
        local ok, s, e = read_ready(stream, kind, arg, term, keep)
        if ok then
            watch_cancel(self)
            if out then
                out.n = 2
                out[1], out[2] = s, e
            end
            return true
        end

        local io = stream.io
        if not (io and io.read_string) then
            stream._sticky_rerr = stream._sticky_rerr or 'backend does not support read_string'
            break
        end

        local want = DEFAULT_READ_CHUNK
        if kind == 'exactly' then
            local need = arg - stream.rx:read_avail()
            if need > 0 and need < want then want = need end
        end

        local data, err, want_dir = io:read_string(want)

        if err ~= nil then
            stream._sticky_rerr = err
            break
        end

        if data == nil then
            watch_arm(self, ctx, (want_dir == 'wr') and 'wr' or 'rd')
            return false
        end

        if data == '' then
            stream._eof = true
            break
        end

        stream.rx:append(data)
        watch_cancel(self)
    end

    -- Terminal now: report readiness based on final state.
    local ok, s, e = read_ready(stream, kind, arg, term, keep)
    assert(ok, 'stream read: reached terminal path but not ready')
    watch_cancel(self)
    if out then
        out.n = 2
        out[1], out[2] = s, e
    end
    return true
end

local function read_commit(self, _ctx)
    if self.done then
        return self.r1, self.r2
    end
    self.done = true

    watch_cancel(self)

    local stream = self.stream
    local a, b = read_consume(stream, self.kind, self.arg, self.term, self.keep)
    if b == 'not ready' then
        a, b = nil, 'inconsistent read commit'
    end

    self.r1, self.r2 = a, b

    lane_release(stream, '_rd_owner', self, stream._rd_waiters, self.lane_node)
    self.waker = nil

    return a, b
end

local function read_rollback(self, _ctx, _why)
    watch_cancel(self)
    local stream = self.stream
    lane_release(stream, '_rd_owner', self, stream._rd_waiters, self.lane_node)
    self.waker = nil
end

local function read_op(stream, kind, arg, opts)
    opts = opts or {}
    local term = opts.terminator or '\n'
    local keep = not not opts.keep_terminator

    if kind == 'line' then
        assert(type(term) == 'string' and term ~= '', 'read_line_op requires non-empty terminator')
    end

    return new_primitive(read_poll, read_commit, read_rollback, {
        done   = false,
        stream = stream,

        kind = kind,
        arg  = arg,
        term = term,
        keep = keep,

        lane_node = { prev = nil, next = nil, inq = false, waker = nil },

        waker = nil,
        watch = nil,

        r1 = nil,
        r2 = nil,
    })
end

function Stream:read_some_op(max)
    assert(self.rx, 'stream is not readable')
    assert(type(max) == 'number' and max >= 0, 'read_some_op: max must be non-negative')
    if max == 0 then return op.always('', nil) end
    return read_op(self, 'some', max)
end

function Stream:read_exactly_op(n)
    assert(self.rx, 'stream is not readable')
    assert(type(n) == 'number' and n >= 0, 'read_exactly_op: n must be non-negative')
    if n == 0 then return op.always('', nil) end
    return read_op(self, 'exactly', n)
end

function Stream:read_line_op(opts)
    assert(self.rx, 'stream is not readable')
    return read_op(self, 'line', nil, opts)
end

function Stream:read_all_op()
    assert(self.rx, 'stream is not readable')
    return read_op(self, 'all', nil)
end

----------------------------------------------------------------------
-- Write op (primitive, shared poll/commit/rollback)
----------------------------------------------------------------------

local function write_poll(self, ctx, out)
    if self.done then
        if out then
            out.n = 2
            out[1], out[2] = self.r1, self.r2
        end
        return true
    end

    local stream = self.stream

    if self.waker and self.waker ~= ctx.waker then
        error('stream write op used from a different fibre', 0)
    end
    self.waker = ctx.waker

    if stream._closed or stream.io == nil then
        self.done = true
        self.r1, self.r2 = self.written, 'closed'
        if out then
            out.n = 2
            out[1], out[2] = self.r1, self.r2
        end
        return true
    end

    if stream._sticky_werr ~= nil then
        self.done = true
        self.r1, self.r2 = self.written, stream._sticky_werr
        if out then
            out.n = 2
            out[1], out[2] = self.r1, self.r2
        end
        return true
    end

    if not lane_acquire(stream, '_wr_owner', self, stream._wr_waiters, self.lane_node, ctx.waker) then
        return false
    end

    local io = stream.io
    if not (io and io.write_string) then
        stream._sticky_werr = stream._sticky_werr or 'backend does not support write_string'
        self.done = true
        self.r1, self.r2 = self.written, stream._sticky_werr
        if out then
            out.n = 2
            out[1], out[2] = self.r1, self.r2
        end
        return true
    end

    while true do
        if self.off >= self.len then
            watch_cancel(self)
            self.done = true
            self.r1, self.r2 = self.written, nil
            if out then
                out.n = 2
                out[1], out[2] = self.r1, self.r2
            end
            return true
        end

        local chunk = self.s:sub(self.off + 1)
        local n, err, want_dir = io:write_string(chunk)

        if err ~= nil then
            stream._sticky_werr = err
            watch_cancel(self)
            self.done = true
            self.r1, self.r2 = self.written, err
            if out then
                out.n = 2
                out[1], out[2] = self.r1, self.r2
            end
            return true
        end

        if n == nil or n == 0 then
            watch_arm(self, ctx, (want_dir == 'rd') and 'rd' or 'wr')
            return false
        end

        self.off     = self.off + n
        self.written = self.written + n
        watch_cancel(self)
    end
end

local function write_commit(self, _ctx)
    watch_cancel(self)
    lane_release(self.stream, '_wr_owner', self, self.stream._wr_waiters, self.lane_node)
    self.waker = nil
    return self.r1, self.r2
end

local function write_rollback(self, _ctx, _why)
    watch_cancel(self)
    lane_release(self.stream, '_wr_owner', self, self.stream._wr_waiters, self.lane_node)
    self.waker = nil
end

local function write_op(stream, str)
    assert(type(str) == 'string', 'write_op expects a string')

    return new_primitive(write_poll, write_commit, write_rollback, {
        done   = false,
        stream = stream,

        lane_node = { prev = nil, next = nil, inq = false, waker = nil },

        waker = nil,
        watch = nil,

        s = str,
        len = #str,
        off = 0,
        written = 0,

        r1 = 0,
        r2 = nil,
    })
end

function Stream:write_op(...)
    assert(self.io, 'stream is closed')
    local n = select('#', ...)
    if n == 0 then return op.always(0, nil) end

    local parts = {}
    for i = 1, n do
        local v = select(i, ...)
        parts[i] = (type(v) == 'string') and v or tostring(v)
    end
    local s = table.concat(parts)
    if s == '' then return op.always(0, nil) end

    return write_op(self, s)
end

function Stream:flush_op()
    -- No buffering: nothing to do.
    return op.always(true, nil)
end

function Stream:close_op()
    return op.always(true, nil):finally(function (aborted)
        if not aborted then
            self:terminate('closed')
        end
    end)
end

----------------------------------------------------------------------
-- Convenience sync wrappers
----------------------------------------------------------------------

local perform = op.perform

function Stream:read_some(max) return perform(self:read_some_op(max)) end
function Stream:read_exactly(n) return perform(self:read_exactly_op(n)) end
function Stream:read_line(opts) return perform(self:read_line_op(opts)) end
function Stream:read_all() return perform(self:read_all_op()) end
function Stream:write(...) return perform(self:write_op(...)) end
function Stream:flush() return perform(self:flush_op()) end
function Stream:close() return perform(self:close_op()) end

----------------------------------------------------------------------
-- Module helper: merge_lines_op (returns name, line, err)
----------------------------------------------------------------------

local function merge_lines_op(named_streams, opts)
    local arms = {}
    for name, s in pairs(named_streams) do
        arms[#arms + 1] = s:read_line_op(opts):wrap(function (line, err)
            return name, line, err
        end)
    end
    return op.choice(unpack(arms))
end

return {
    open           = open,
    is_stream      = is_stream,
    merge_lines_op = merge_lines_op,
    Stream         = Stream,
}
