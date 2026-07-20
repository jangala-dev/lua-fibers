-- Blocking getaddrinfo resolver for FFI-backed POSIX host families.
--
-- The host advertises resolver_blocking=true. Embedders which cannot tolerate a
-- blocking resolver call should replace this capability with a worker-backed or
-- native asynchronous resolver.

local HostError = require('fibers.host.error')

local Common = {}

function Common.new(opts)
  opts = opts or {}
  local ffi = assert(opts.ffi, 'ffi provider required')
  local C = opts.C or ffi.C
  local tonumber_c = opts.tonumber_c or rawget(ffi, 'tonumber') or tonumber

  local ok_cdef, cdef_err = pcall(function()
    ffi.cdef([[
      struct addrinfo {
        int ai_flags;
        int ai_family;
        int ai_socktype;
        int ai_protocol;
        unsigned int ai_addrlen;
        struct sockaddr *ai_addr;
        char *ai_canonname;
        struct addrinfo *ai_next;
      };
      int getaddrinfo(const char *node, const char *service,
                      const struct addrinfo *hints,
                      struct addrinfo **res);
      void freeaddrinfo(struct addrinfo *res);
      const char *gai_strerror(int errcode);
    ]])
  end)

  local AF_UNSPEC = 0
  local AF_INET = 2
  local AF_INET6 = 10
  local SOCK_STREAM = 1

  local function null(ptr)
    if ptr == nil then
      return true
    end
    local nullptr = rawget(ffi, 'nullptr')
    return nullptr ~= nil and ptr == nullptr
  end

  local function address_from(ai, service)
    local port = tonumber(service)
    if ai.ai_family == AF_INET then
      local sa = ffi.cast('struct sockaddr_in *', ai.ai_addr)
      local buf = ffi.new('char[64]')
      local ptr = C.inet_ntop(AF_INET, sa.sin_addr, buf, 64)
      if null(ptr) then
        return nil
      end
      return {
        kind = 'inet4',
        family = 'inet4',
        host = ffi.string(buf),
        port = tonumber_c(C.ntohs(sa.sin_port)) or port,
      }
    end
    if ai.ai_family == AF_INET6 then
      local sa = ffi.cast('struct sockaddr_in6 *', ai.ai_addr)
      local buf = ffi.new('char[128]')
      local ptr = C.inet_ntop(AF_INET6, sa.sin6_addr.s6_addr, buf, 128)
      if null(ptr) then
        return nil
      end
      return {
        kind = 'inet6',
        family = 'inet6',
        host = ffi.string(buf),
        port = tonumber_c(C.ntohs(sa.sin6_port)) or port,
        flowinfo = tonumber_c(sa.sin6_flowinfo) or 0,
        scope_id = tonumber_c(sa.sin6_scope_id) or 0,
      }
    end
    return nil
  end

  local Resolver = {}

  function Resolver.is_supported()
    local ok, reason = pcall(function()
      ffi.typeof('struct addrinfo')
      return C.getaddrinfo, C.freeaddrinfo, C.gai_strerror
    end)
    if not ok then
      return false, reason or cdef_err
    end
    return true
  end

  function Resolver.support_reason()
    local ok, reason = Resolver.is_supported()
    if ok then
      return nil
    end
    return reason or cdef_err or 'getaddrinfo resolver functions unavailable'
  end

  function Resolver.resolve(_host, endpoint, resolve_opts)
    resolve_opts = resolve_opts or {}
    local hints = ffi.new('struct addrinfo[1]')
    local family = resolve_opts.family or endpoint.family_hint
    if family == 'inet4' then
      hints[0].ai_family = AF_INET
    elseif family == 'inet6' then
      hints[0].ai_family = AF_INET6
    else
      hints[0].ai_family = AF_UNSPEC
    end
    hints[0].ai_socktype = SOCK_STREAM

    local result = ffi.new('struct addrinfo *[1]')
    local service = tostring(endpoint.service)
    local rc = tonumber_c(C.getaddrinfo(endpoint.host, service, hints, result))
    if rc ~= 0 then
      local message = 'address resolution failed'
      local p = C.gai_strerror(rc)
      if not null(p) then
        message = ffi.string(p)
      end
      return nil,
        HostError.system('resolver', 'resolve', message, 'EAI_' .. tostring(rc), rc, {
          endpoint = endpoint,
        })
    end

    local out = {}
    local seen = {}
    local ai = result[0]
    while not null(ai) do
      local address = address_from(ai[0], endpoint.service)
      if address then
        local key = address.kind
          .. ':'
          .. address.host
          .. ':'
          .. tostring(address.port)
          .. ':'
          .. tostring(address.scope_id or 0)
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = address
        end
      end
      ai = ai.ai_next
    end
    C.freeaddrinfo(result[0])

    if #out == 0 then
      return nil,
        HostError.system(
          'resolver',
          'resolve',
          'name resolved to no usable stream addresses',
          'EAI_NONAME',
          nil,
          {
            endpoint = endpoint,
          }
        )
    end
    return out
  end

  return Resolver
end

return Common
