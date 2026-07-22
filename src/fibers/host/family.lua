-- Atomic host-family construction.
--
-- One family owns every native capability.  Shared host semantics are defined
-- here; family modules supply coherent native services and one blocking driver.

local Host = require('fibers.host')
local HostError = require('fibers.host.error')
local HostWait = require('fibers.host.wait')
local PollPlan = require('fibers.host.poll_plan')

local Family = {}

function Family.unsupported(prefix, reason, methods)
  local value = {
    is_supported = function()
      return false, reason
    end,
    support_reason = function()
      return reason
    end,
  }
  for _, name in ipairs(methods or { 'new' }) do
    value[name] = function()
      error(prefix .. ': ' .. tostring(reason), 2)
    end
  end
  return value
end

local function supported(module)
  return module and (type(module.is_supported) ~= 'function' or module.is_supported())
end
local function capability(module, name)
  if not supported(module) then
    return false
  end
  return not name or type(module[name]) ~= 'function' or not not module[name]()
end

local function default_capabilities(spec)
  local socket, datagram = capability(spec.socket), capability(spec.datagram)
  local resolver, process, fd = capability(spec.resolver), capability(spec.process), capability(spec.fd)
  local out = {
    time = true,
    readiness = true,
    fd = fd,
    pipe = fd,
    socket = socket,
    socket_ipv4 = socket and capability(spec.socket, 'supports_ipv4'),
    socket_ipv6 = socket and capability(spec.socket, 'supports_ipv6'),
    socket_unix = socket and capability(spec.socket, 'supports_unix'),
    datagram = datagram,
    datagram_truncation = spec.datagram_truncation == true,
    resolver = resolver,
    resolver_blocking = resolver,
    process = process,
    file = process,
    file_backend = process and 'worker' or nil,
    file_io_uring = false,
    file_aio_detected = false,
  }
  for key, value in pairs(spec.capabilities or {}) do
    out[key] = value
  end
  return out
end

function Family.define(spec)
  local Module, HostClass = {}, {}
  HostClass.__index = HostClass

  function Module.is_supported()
    local ok = spec.is_supported()
    return not not ok
  end
  function Module.support_reason()
    if Module.is_supported() then
      return nil
    end
    return spec.support_reason and spec.support_reason()
      or ('required ' .. spec.name .. ' functions unavailable')
  end

  function Module.new(opts)
    opts = opts or {}
    if not Module.is_supported() then
      error(spec.prefix .. ': ' .. tostring(Module.support_reason()), 2)
    end
    local state = spec.create and spec.create(opts) or {}
    state.kind, state.name, state.family = spec.name, spec.name, spec.family
    state.fd = spec.fd
    state.capabilities = spec.capability_builder and spec.capability_builder() or default_capabilities(spec)
    state.on_wait, state.on_wake, state.on_unsupported = opts.on_wait, opts.on_wake, opts.on_unsupported
    state.now = state.now or function()
      return spec.now()
    end
    return setmetatable(state, HostClass)
  end

  function HostClass:create_pipe(opts)
    return spec.fd.pipe({
      host = self,
      name = opts and opts.name,
      nonblocking = opts == nil or opts.nonblocking ~= false,
    })
  end
  function HostClass:create_listener(address, opts)
    return spec.socket.create_listener(self, address, opts)
  end
  function HostClass:start_dial(address, opts)
    return spec.socket.start_dial(self, address, opts)
  end
  function HostClass:create_datagram(address, opts)
    return spec.datagram.create_datagram(self, address, opts)
  end
  function HostClass:resolve(endpoint, opts)
    if not supported(spec.resolver) then
      return nil, HostError.unsupported('host', 'resolve', { endpoint = endpoint })
    end
    return spec.resolver.resolve(self, endpoint, opts)
  end
  function HostClass:start_process(process_spec)
    if not supported(spec.process) then
      return nil, nil, HostError.unsupported('host', 'process', { host = self.name })
    end
    return spec.process.start_process(self, process_spec)
  end
  function HostClass:file_provider(runtime, opts)
    if spec.file_provider then
      return spec.file_provider(self, runtime, opts)
    end
    if self.capabilities.process then
      return require('fibers.file.worker_provider').new(runtime, opts)
    end
  end
  function HostClass:sleep(seconds)
    return spec.sleep(seconds)
  end
  function HostClass:block(rt, waits, status, opts)
    return spec.block(self, rt, waits, status, opts)
  end
  function HostClass:close()
    if spec.close then
      return spec.close(self)
    end
  end

  for name, method in pairs(spec.methods or {}) do
    HostClass[name] = method
  end
  Module.Class = HostClass
  return Module
end

function Family.polling(spec)
  spec.block = function(self, rt, waits, status)
    waits = waits or {}
    local deadline = Host.earliest_deadline(waits)
    local plan = PollPlan.build(waits, spec.poll_keys)
    if plan.unsupported then
      if self.on_unsupported then
        self.on_unsupported(waits, status)
      end
      return nil, 'unsupported-readiness-key'
    end
    if #plan.records == 0 then
      return HostWait.block_without_io(self, rt, waits, status, deadline)
    end
    local ready, reason = spec.poll(plan, Host.timeout_ms(rt, deadline))
    if not ready then
      return true, reason or 'poll-interrupted'
    end
    local delivered = false
    for i = 1, #ready do
      local item = ready[i]
      if PollPlan.deliver(rt, item.record, item.read, item.write) then
        delivered = true
      end
    end
    if delivered then
      return true, 'readiness'
    end
    if deadline ~= nil and rt:now() >= deadline then
      return true, 'time'
    end
    return true, 'poll'
  end
  return Family.define(spec)
end

return Family
