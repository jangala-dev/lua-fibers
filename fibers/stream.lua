--- Module implementing a fiber-aware streaming I/O interface.
-- This module provides an abstraction layer over typical I/O operations,
-- facilitating buffered reads and writes with non-blocking support
-- in a fiber-based concurrency framework.
-- @module fibers.stream

local sc = require 'fibers.utils.syscall'
local buffer              = require 'fibers.utils.fixed_buffer'
local op  = require 'fibers.op'

local ffi = sc.is_LuaJIT and require 'ffi' or require 'cffi'
local unpack = table.unpack or unpack  -- luacheck: ignore -- Compatibility fallback

local Stream = {}
Stream.__index = Stream

local DEFAULT_BUFFER_SIZE = 2^12 -- 4096 bytes as a sensible default buffer size

--- Open a new stream.
-- Creates and returns a new stream object.
-- @param io The underlying I/O object to wrap. Must support read, write, and optionally seek.
-- @param readable Whether the stream should be readable. Defaults to true if not specified.
-- @param writable Whether the stream should be writable. Defaults to true if not specified.
-- @param buffer_size The size of the buffer to use for the stream. Defaults to 4096 bytes.
-- @return A new stream object.
local function open(io, readable, writable, buffer_size)
    local ret = setmetatable(
        { io = io, line_buffering = false, random_access = false },
        Stream)
    if readable ~= false then
        ret.rx = buffer.new(buffer_size or DEFAULT_BUFFER_SIZE)
    end
    if writable ~= false then
        ret.tx = buffer.new(buffer_size or DEFAULT_BUFFER_SIZE)
    end
    if io.seek and io:seek(sc.SEEK_CUR, 0) then ret.random_access = true end
    return ret
end

--- Check if an object is a stream.
-- @param x The object to check.
-- @return True if the object is a stream, false otherwise.
local function is_stream(x)
    return type(x) == 'table' and getmetatable(x) == Stream
end

--- Set the stream to non-blocking mode.
function Stream:nonblock() self.io:nonblock() end

--- Set the stream to blocking mode.
function Stream:block() self.io:block() end

local function core_write_op(stream, buf, count, flush_needed)
    buf = ffi.cast('uint8_t*', buf)
    local tally = 0
    local write_directly
    local function write_attempt()
        while true do
            if flush_needed then
                while not stream.tx:is_empty() do
                    local written, err = stream.io:write(stream.tx:peek()) -- Write current contiguous block
                    if err then return true, tally, err end
                    if written == nil then                                 -- block indicated by nil return
                        stream._part_write.tally = tally
                        return false
                    end
                    if written == 0 then return true, tally, nil end -- EOF
                    stream.tx:advance_read(written)
                end
                flush_needed = nil
            end
            if tally == count then return true, tally end
            if write_directly then
                local written, err = stream.io:write(buf + tally, count - tally)
                if err then return true, tally, err end
                if written == nil then
                    stream._part_write.tally = tally
                    return false
                end                                              -- Would block
                if written == 0 then return true, tally, nil end -- EOF
                tally = tally + written
            else
                local to_write = math.min(stream.tx:write_avail(), count - tally)
                stream.tx:write(buf + tally, to_write)
                tally = tally + to_write
                -- Do we need to flush?
                flush_needed = stream.tx:is_full() or stream.line_buffering and stream.tx:find('\n')
            end
        end
    end
    local function try()
        stream._part_write = { buf = buf, count = count, tally = 0 }
        write_directly = count >= stream.tx.size -- captures both large writes and no buffering
        return write_attempt()
    end
    local function block(suspension, wrap_fn)
        local task = {}
        task.run = function(_)
            if not suspension:waiting() then return end
            local success, _, err = write_attempt()
            if success then
                suspension:complete(wrap_fn, tally, err)
            else
                stream.io:task_on_writable(task)
            end
        end
        stream.io:task_on_writable(task)
    end
    local function wrap(...)
        stream._part_write = nil -- clean up on write success
        return ...
    end
    return op.new_base_op(wrap, try, block)
end

function Stream:partial_write()
    if self._part_write then return self._part_write.tally end
end

function Stream:reset_partial_write()
    self._part_write = nil
end

function Stream:write_bytes_op(buf, count)
    return core_write_op(self, buf, count)
end

--- Write a sequence of bytes to the stream.
-- @param buf pointer to data buffer
-- @param count number of bytes to write
-- @return number of bytes written
-- @return error encountered during the write
function Stream:write_bytes(buf, count)
    return self:write_bytes_op(buf, count):perform()
end

function Stream:write_chars_op(n)
    return self:write_bytes_op(ffi.cast('uint8_t*', n), #n)
end

--- Write a string to the stream.
-- @param n string to write
-- @return number of bytes written
-- @return error encountered during the write
function Stream:write_chars(n)
    return self:write_chars_op(n):perform()
end

-- Extend a C array by at least 'extension' bytes
-- @param arr C array to extend
-- @param size current used portion of C array
-- @param extension intended extra portion of C array to be used
-- @return arr extended C array
local function extend(arr, size, extension)
    if size + extension > ffi.sizeof(arr) then
        local new_size = math.max(ffi.sizeof(arr) * 2, size + extension)
        local new_buf = ffi.new('uint8_t[?]', new_size)
        ffi.copy(new_buf, arr, size) -- Copy existing data to new buffer
        arr = new_buf
    end

    return arr
end
local function core_read_op(stream, buf, min, max, terminator)
    local tally = 0
    local function find_terminator()
        local term_loc = stream.rx:find(terminator)
        if term_loc then
            local final = tally + term_loc + #terminator
            return final, final
        end
        return min, max
    end
    local function read_attempt()
        while true do
            if terminator then
                min, max = find_terminator()
            end
            local from_buffer = math.min(stream.rx:read_avail(), max - tally)

            -- Extend the buffer if needed
            buf = extend(buf, tally, from_buffer)

            stream.rx:read(buf + tally, from_buffer)
            tally = tally + from_buffer
            if tally >= min then return true, buf, tally end -- min achieved, returning
            stream.rx:reset()                                -- buffer emptied, so reset for io:read()
            local ptr, _ = stream.rx:reserve(stream.rx.size)
            local did_read, err = stream.io:read(ptr, stream.rx.size)

            stream.rx:commit(did_read or 0)

            if err then
                return true, buf, tally, err
            elseif did_read == nil then -- Would block
                stream._part_read.tally = tally
                return false
            elseif did_read == 0 then -- EOF
                return true, buf, tally, nil
            end
        end
    end
    local function try()
        stream._part_read = { buf = buf, tally = 0 }
        return read_attempt()
    end
    local function block(suspension, wrap_fn)
        local task = {}
        task.run = function()
            if not suspension:waiting() then return end
            local success, _, _, err = read_attempt()
            if success then
                suspension:complete_and_run(wrap_fn, buf, tally, err)
            else
                stream.io:task_on_readable(task)
            end
        end
        stream.io:task_on_readable(task)
    end
    local function wrap(...)
        stream._part_read = nil -- clean up on write success
        return ...
    end
    return op.new_base_op(wrap, try, block)
end

function Stream:partial_read()
    if self._part_read then return self._part_read.tally, ffi.string(self._part_read.buf, self._part_read.tally) end
end

function Stream:reset_partial_read()
    self._part_read = nil
end

--- Operation to read a specified number of bytes from the stream.
-- @param buf The buffer to store the read data.
-- @param count The number of bytes to read.
-- @return operation
function Stream:read_bytes_op(buf, count)
    return core_read_op(self, buf, count, count):wrap(function(ret_buf, cnt, err) return ret_buf, cnt, err end)
end

--- Read a specified number of bytes from the stream.
-- This function blocks until the exact number of bytes is read or the stream is closed.
-- @param buf The buffer to store the read data.
-- @param count The number of bytes to read.
-- @return the buffer
-- @return the number of bytes read
-- @return error during read, if any
function Stream:read_bytes(buf, count)
    return self:read_bytes_op(buf, count):perform()
end

--- Operation to read up to a specified number of bytes from the stream.
-- @param buf The buffer to store the read data.
-- @param count The number of bytes to read.
-- @return operation
function Stream:read_some_bytes_op(buf, count)
    return core_read_op(self, buf, 1, count):wrap(function(_, cnt, err) return cnt, err end)
end

--- Read up to a specified number of bytes from the stream.
-- @param buf buffer to read into
-- @param count maximum number of bytes to read
-- @return number of bytes read
-- @return error during read, if any
function Stream:read_some_bytes(buf, count)
    return self:read_some_bytes_op(buf, count):perform()
end

--- Operation to read all bytes from the stream into a buffer.
-- @return operation
function Stream:read_all_bytes_op()
    local buf = ffi.new('uint8_t[?]', self.rx.size)
    return self:read_bytes_op(buf, math.huge)
end

--- Read all bytes from the stream into a buffer.
-- @return buffer containing all read bytes
-- @return error during read, if any
function Stream:read_all_bytes()
    return self:read_all_bytes_op():perform()
end

--- Operation to read all bytes from the stream into a buffer.
-- @return operation
function Stream:read_byte_op()
    local buf = ffi.new('uint8_t[?]', 1)
    return core_read_op(self, buf, 1, 1):wrap(function(_, cnt, err) return cnt==1 and buf[0] or nil, err end)
end

--- Read a single byte from the stream.
-- @return the byte read, or nil if at end of file
-- @return error during read, if any
function Stream:read_byte()
    return self:read_byte_op():perform()
end

--- Operation to read a specified number of characters from the stream.
-- @param count number of characters to read
-- @return operation
function Stream:read_chars_op(count)
    local buf = ffi.new('uint8_t[?]', count)
    return self:read_bytes_op(buf, count):wrap(function(ret_buf, cnt, err)
        if cnt == 0 then
            return nil, err
        else
            return ffi.string(ret_buf, cnt), err
        end
    end)
end

--- Read a specified number of characters from the stream.
-- @param count number of characters to read
-- @return string containing the characters read
-- @return error during read, if any
function Stream:read_chars(count)
    return self:read_chars_op(count):perform()
end

--- Operation to read up to a specified number of characters from the stream.
-- @param count maximum number of characters to read
-- @return operation
function Stream:read_some_chars_op(count)
    if count == nil then count = self.rx.size end
    local buf = ffi.new('uint8_t[?]', count)
    return core_read_op(self, buf, 1, count):wrap(
        function(ret_buf, cnt, err) return cnt > 0 and ffi.string(ret_buf, cnt) or nil, err end
    )
end

--- Read up to a specified number of characters from the stream.
-- @param count maximum number of characters to read
-- @return string containing the characters read
-- @return error during read, if any
function Stream:read_some_chars(count)
    return self:read_some_chars_op(count):perform()
end

--- Operation to read all characters from the stream.
-- @return operation
function Stream:read_all_chars_op()
    return self:read_all_bytes_op():wrap(function(buf, cnt, err) return ffi.string(buf, cnt), err end)
end

--- Read all characters from the stream.
-- @return string containing all characters read
-- @return error during read, if any
function Stream:read_all_chars()
    return self:read_all_chars_op():perform()
end

--- Operation to read a single character from the stream.
-- @return operation
function Stream:read_char_op()
    return self:read_byte_op():wrap(function(byte) return byte and string.char(byte) or nil end)
end

--- Read a single character from the stream.
-- @return the character read, or nil if at end of file
-- @return error during read, if any
function Stream:read_char()
    return self:read_char_op():perform()
end

--- Operation to read a line from the stream.
-- @param style 'keep' to keep the line terminator, 'discard' to remove it (default 'discard')
-- @return operation
function Stream:read_line_op(style)
    style = style or 'discard'
    local buf = ffi.new('uint8_t[?]', self.rx.size)
    return core_read_op(self, buf, math.huge, math.huge, "\n"):wrap(
        function(ret_buf, cnt) return cnt>0 and ffi.string(ret_buf, style=='keep' and cnt or cnt-1) or nil end
    )
end

--- Read a line from the stream.
-- @param style 'keep' to keep the line terminator, 'discard' to remove it (default 'discard')
-- @return the line read, or nil if at end of file
-- @return error during read, if any
function Stream:read_line(style)
    return self:read_line_op(style):perform()
end

function Stream:flush_input()
    if self.random_access and self.rx then
        local buffered = self.rx:read_avail()
        if buffered ~= 0 then
            assert(self.io:seek('cur', -buffered))
            self.rx:reset()
        end
    end
end

function Stream:flush_output_op()
    return core_write_op(self, nil, 0, true)
end

--- Flush the output buffer, writing all buffered data to the underlying IO.
function Stream:flush_output()
    return self:flush_output_op():perform()
end

Stream.flush = Stream.flush_output

--- Close the stream, optionally flushing remaining data.
-- @return true on success, followed by any additional return values from the underlying IO close operation
function Stream:close()
    if self.tx then self:flush_output() end
    self.rx, self.tx = nil, nil
    local success, exit_type, code = self.io:close()
    self.io = nil
    return success, exit_type, code
end

--- Create an iterator over lines in the stream.
-- The iterator returns each line, stripped of its end-of-line marker.
-- @return function iterator over lines
function Stream:lines(...)
    local formats = { ... }
    if #formats == 0 then
        return function() return self:read_line('discard') end -- Fast path.
    end
    return function() return self:read(unpack(formats)) end
end

--- Lua 5.1 inspired file:read_op() method.
-- The function supports various formats to control the reading behavior.
-- @param ... format (optional) specifies the reading format:
--    '*a': reads the whole file from the current position to the end.
--    '*l': reads the next line not including the end of the line.
--    '*L': reads the next line including the end of the line.
--    number: reads a string up to the number of characters specified.
-- If no format is specified, it defaults to reading the next line without the end-of-line marker.
-- @return operation to perform the read based on the specified format
function Stream:read_op(...)
    assert(self.rx, "expected a readable stream")
    local args = { ... }
    if #args == 0 then return self:read_line_op('discard') end -- Default format.
    if #args > 1 then error('multiple formats unimplemented') end
    local format = args[1]
    if format == '*n' then
        -- "*n": reads a number; this is the only format that returns a
        -- number instead of a string.
        error('read numbers unimplemented')
    elseif format == '*a' then
        -- "*a": reads the whole file, starting at the current
        -- position. On end of file, it returns the empty string.
        return self:read_all_chars_op()
    elseif format == '*l' then
        -- "*l": reads the next line (skipping the end of line), returning
        -- nil on end of file.
        return self:read_line_op('discard')
    elseif format == '*L' then
        -- "*L": reads the next line keeping the end of line (if present),
        -- returning nil on end of file.  (Lua 5.2, present in LuaJIT.)
        return self:read_line_op('keep')
    else
        -- /number/: reads a string with up to this number of characters,
        -- returning nil on end of file.
        assert(type(format) == 'number' and format > 0, 'bad format')
        local number = format
        return self:read_chars_op(number)
    end
end

--- Lua 5.1's file:read() method.
-- This method simplifies reading data by automatically performing the operation initiated by `read_op`.
-- @param ... format (optional) specifies the reading format. Refer to `read_op` for details.
-- @return the data read from the stream according to the specified format, or nil on end of file
-- @return error during read, if any
function Stream:read(...)
    return self:read_op(...):perform()
end

--- Get or set the file position.
-- @param whence base for the offset: 'set', 'cur', or 'end'
-- @param offset offset from the base, in bytes
-- @return new position, or nil and an error message if the operation fails
function Stream:seek(whence, offset)
    if not self.random_access then return nil, 'stream is not seekable' end
    if whence == nil then whence = sc.SEEK_CUR end
    if offset == nil then offset = 0 end
    if whence == sc.SEEK_CUR and offset == 0 then
        -- Just a position query.
        local ret, err = self.io:seek(sc.SEEK_CUR, 0)
        if ret == nil then return ret, err end
        if self.tx and self.tx:read_avail() ~= 0 then
            return ret + self.tx:read_avail()
        end
        if self.rx and self.rx:read_avail() ~= 0 then
            return ret - self.rx:read_avail()
        end
        return ret
    end
    if self.rx then self:flush_input() end; if self.tx then self:flush_output() end
    return self.io:seek(whence, offset)
end

local function transfer_buffered_bytes(old, new)
    while old:read_avail() > 0 do
        local buf, count = old:peek()
        new:write(buf, count)
        old:advance_read(count)
    end
end

--- Set the buffering mode for the stream.
-- Adjusts the buffering strategy for the stream's input and output.
-- @param mode The buffering mode: 'no', 'line', or 'full'.
-- @param size The size of the buffer, in bytes. Defaults to DEFAULT_BUFFER_SIZE if not specified.
-- @return The stream object.
function Stream:setvbuf(mode, size)
    -- Sets the buffering mode for an output file.
    if mode == 'no' then
        self.line_buffering, size = false, 1
    elseif mode == 'line' then
        self.line_buffering = true
    elseif mode == 'full' then
        self.line_buffering = false
    else
        error('bad mode', mode)
    end

    if size == nil then size = DEFAULT_BUFFER_SIZE end
    if self.rx and self.rx.size ~= size then
        if self.rx:read_avail() > size then
            error('existing buffered input is too much for new buffer size')
        end
        local new_rx = buffer.new(size)
        transfer_buffered_bytes(self.rx, new_rx)
        self.rx = new_rx
    end
    if self.tx and self.tx.size ~= size then
        -- Note >= rather than > as we never leave tx buffers full.
        while self.tx:read_avail() >= size do self:flush() end
        local new_tx = buffer.new(size)
        transfer_buffered_bytes(self.tx, new_tx)
        self.tx = new_tx
    end
    return self
end

--- Lua 5.1 inspired file:write_op() method.
-- Returns an op that will write the value of each of its arguments to the
-- file. The arguments must be strings or numbers. To write other values,
-- use tostring or string.format before write.
-- @param ... arguments to write (must be strings or numbers)
-- @return operation
function Stream:write_op(...)
    local n = select('#', ...)
    for i = 1, n do
        local arg = select(i, ...)
        if type(arg)~="number" and type(arg)~="string" then
            return nil, 'arguments must be strings or numbers'
        end
    end
    return self:write_chars_op(table.concat({...}))
end

--- Lua 5.1 file:write() method.
-- Write the value of each of its arguments to the file. The arguments must be
-- strings or numbers. To write other values, use tostring or string.format
-- before write.
-- @param ... data to write (strings or numbers)
-- @return true on success, or nil plus an error message on failure
function Stream:write(...)
    return self:write_op(...):perform()
end

-- The result may be nil.
function Stream:filename() return self.io.filename end

return {
    open = open,
    is_stream = is_stream
}
