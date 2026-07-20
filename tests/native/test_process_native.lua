local Contract = require('tests.support.process_provider_contract')

local exercised = 0
local reasons = {}
for _, spec in ipairs({
  { module = 'fibers.host.luajit_linux', name = 'luajit_linux' },
  { module = 'fibers.host.cffi_linux', name = 'cffi_linux' },
  { module = 'fibers.host.luaposix', name = 'luaposix' },
  { module = 'fibers.host.nixio', name = 'nixio' },
}) do
  local ok, host_module = pcall(require, spec.module)
  local supported, reason = false, ok and nil or host_module
  if ok and host_module and type(host_module.is_supported) == 'function' then
    supported, reason = host_module.is_supported()
  end
  if supported then
    local host = host_module.new()
    if host.capabilities.process then
      local contract_ok, contract_err = pcall(Contract.exercise, spec.name, host)
      if type(host.close) == 'function' then host:close() end
      assert(contract_ok, contract_err)
      exercised = exercised + 1
    else
      if type(host.close) == 'function' then host:close() end
      reasons[#reasons + 1] = spec.name .. ': process capability unavailable'
    end
  else
    reasons[#reasons + 1] = spec.name .. ': ' .. tostring(reason or 'host unavailable')
  end
end

if exercised == 0 then
  return { status = 'skip', reason = table.concat(reasons, '; ') }
end
return true
