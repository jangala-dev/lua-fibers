rockspec_format = "3.0"

package = "nixio"
version = "0.4.1-1"

source = {
  url = "https://github.com/Neopallium/nixio/archive/e9f9183c3ed134724ccced98286ba3efad6b21d2.tar.gz",
  dir = "nixio-e9f9183c3ed134724ccced98286ba3efad6b21d2",
}

description = {
  summary = "System, networking and I/O library for Lua",
  detailed = [[
Nixio is a multi-platform library providing networking, file I/O,
filesystem operations, process control, polling and related POSIX facilities.
This development rockspec pins upstream release v0.4.1 to an exact commit.
It also supplies the standard limits header required by process.c when the
selected Lua headers do not include it indirectly.
]],
  homepage = "https://github.com/Neopallium/nixio",
  license = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
}

external_dependencies = {
  OPENSSL = {
    header = "openssl/ssl.h",
  },
}

build = {
  type = "make",
  build_variables = {
    NIXIO_CFLAGS = "-include limits.h",
    NIXIO_LDFLAGS = "-lcrypt -L$(OPENSSL_LIBDIR)",
    LUA_CFLAGS = "$(CFLAGS) -I$(LUA_INCDIR)",
  },
  install_variables = {
    NIXIO_CFLAGS = "-include limits.h",
    LUA_MODULEDIR = "$(LUADIR)",
    LUA_LIBRARYDIR = "$(LIBDIR)",
  },
}
