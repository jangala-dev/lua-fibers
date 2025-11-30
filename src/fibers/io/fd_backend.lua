-- fibers/io/fd_backend.lua
--
-- FD-backed backend shim.
-- Chooses the best available implementation:
--   1. FFI-based (no luaposix dependency),
--   2. luaposix-based (no FFI dependency).
--
-- Backend contract towards fibers.io.stream:
--   * kind()              -> "fd"
--   * fileno()            -> fd
--   * read_string(max)    -> str|nil, err|nil
--        - str == nil  : would block
--        - str == ""   : EOF
--   * write_string(str)   -> n|nil, err|nil
--        - n == nil    : would block
--   * on_readable(task)   -> token{ unlink = fn }
--   * on_writable(task)   -> token{ unlink = fn }
--   * close()             -> ok, err|nil
--   * seek(whence, off)   -> pos|nil, err|nil
--        - whence: "set" | "cur" | "end"
---@module 'fibers.io.fd_backend'

local candidates = {
  'fibers.io.fd_backend.ffi',   -- FFI / libc
  -- 'fibers.io.fd_backend.posix', -- luaposix
}

for _, name in ipairs(candidates) do
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" and mod.is_supported and mod.is_supported() then
    return mod
  end
end

error("fibers.io.fd_backend: no suitable fd backend available on this platform")
