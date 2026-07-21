-- POSIX AIO capability probe.
--
-- POSIX AIO can accelerate descriptor reads, writes and synchronisation, but
-- it is not a complete regular-file provider: opening files, closing the final
-- descriptor and path mutations still require another evented mechanism. The
-- capability is therefore reported separately from the selected file backend.

local Probe = {}
local cdef_done = setmetatable({}, { __mode = 'k' })

function Probe.available(ffi, C)
  if not ffi or not C then
    return false
  end
  local ok_cdef = cdef_done[ffi] == true
  if not ok_cdef then
    ok_cdef = pcall(function()
      ffi.cdef([[
      struct aiocb;
      int aio_read(struct aiocb *);
      int aio_write(struct aiocb *);
      int aio_fsync(int, struct aiocb *);
      int aio_error(const struct aiocb *);
      long aio_return(struct aiocb *);
      int aio_cancel(int, struct aiocb *);
      ]])
    end)
    if ok_cdef then
      cdef_done[ffi] = true
    end
  end
  if not ok_cdef then
    return false
  end
  local ok, available = pcall(function()
    return C.aio_read ~= nil
      and C.aio_write ~= nil
      and C.aio_fsync ~= nil
      and C.aio_error ~= nil
      and C.aio_return ~= nil
      and C.aio_cancel ~= nil
  end)
  return ok and available == true
end

return Probe
