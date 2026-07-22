# Test profiles

Fibers separates three different questions which should not be multiplied
indiscriminately across every Lua interpreter.

- `make test` runs the normal semantic suite plus native smoke tests available
  to the selected interpreter. It excludes sustained churn.
- `make test-matrix` runs interpreter-sensitive semantics across supported Lua
  versions, LuaJIT and TexLua. It excludes native provider integration and
  stress loops.
- `make test-native` runs provider and real-kernel integration under Lua 5.4
  and LuaJIT.
- `make test-stress` runs registration, connection and descriptor churn.
- `make test-full` combines the matrix, native, stress, reference and examples
  for release qualification.

The environment variable `FIBERS_TEST_PROFILE` accepts `default`, `matrix`, or
`full` when invoking `tests/run_all.lua` directly. Stress loop sizes may be
raised with `FIBERS_STRESS_SOCKET_CYCLES` and
`FIBERS_STRESS_DATAGRAM_CYCLES`.

## TexLua and Luau

`make test-texlua` runs the stock matrix profile under the Lua 5.3-derived
TexLua interpreter.  It is part of `make test-matrix`.

Luau uses a generated portable target because its module loader and host
environment differ from stock Lua:

```sh
make build-luau
make check-luau
make test-luau
```

Luau remains outside `make test-matrix` until the generated portable profile
meets the gates in [Luau build programme](luau.md).
