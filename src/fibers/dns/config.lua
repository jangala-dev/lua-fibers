-- DNS stub-resolver configuration.
--
-- Explicit options take precedence. When no name servers are supplied the
-- conventional resolv.conf file is loaded lazily through fibers.file. No host
-- resolver or getaddrinfo call is used.

local Address = require('fibers.net.address')
local File = require('fibers.file')

local function finite_number(value, fallback, minimum, maximum)
  value = tonumber(value)
  if value == nil then
    value = fallback
  end
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return fallback
  end
  return math.min(maximum, math.max(minimum, value))
end

local function bounded_integer(value, fallback, minimum, maximum)
  return math.floor(finite_number(value, fallback, minimum, maximum))
end

local Config = {}

local function copy_list(values)
  local out = {}
  for i = 1, #(values or {}) do
    out[i] = values[i]
  end
  return out
end

local function strip_comment(line)
  local hash = string.find(line, '#', 1, true)
  local semicolon = string.find(line, ';', 1, true)
  local cut
  if hash and semicolon then
    cut = math.min(hash, semicolon)
  else
    cut = hash or semicolon
  end
  return cut and string.sub(line, 1, cut - 1) or line
end

local function numeric_address(value, default_port)
  if type(value) == 'table' then
    local address = Address.validate(value, 'DNS name server')
    if address.kind ~= 'inet4' and address.kind ~= 'inet6' then
      error('DNS name server must be an IPv4 or IPv6 address', 3)
    end
    if address.port == 0 then
      address = Address.with_port(address, default_port)
    end
    return address
  end
  if type(value) ~= 'string' or value == '' then
    error('DNS name server must be a numeric address', 3)
  end
  local host, port = value, default_port
  local bracket_host, bracket_port = string.match(value, '^%[([^%]]+)%]:(%d+)$')
  if bracket_host then
    host, port = bracket_host, tonumber(bracket_port)
  else
    local v4_host, v4_port = string.match(value, '^([%d%.]+):(%d+)$')
    if v4_host then
      host, port = v4_host, tonumber(v4_port)
    end
  end
  if string.find(host, ':', 1, true) then
    return Address.ipv6(host, port)
  end
  if not string.match(host, '^%d+%.%d+%.%d+%.%d+$') then
    error('DNS name server must be numeric: ' .. tostring(value), 3)
  end
  return Address.ipv4(host, port)
end

local function parse_options(words, target)
  for i = 2, #words do
    local key, value = string.match(words[i], '^([^:]+):(.+)$')
    if key == 'timeout' then
      target.timeout = finite_number(value, target.timeout, 0.01, 30.0)
    elseif key == 'attempts' then
      target.attempts = bounded_integer(value, target.attempts, 1, 16)
    elseif key == 'ndots' then
      target.ndots = bounded_integer(value, target.ndots, 0, 15)
    end
  end
end

function Config.parse_resolv_conf(text, opts)
  opts = opts or {}
  local parsed = {
    nameservers = {},
    search = {},
    timeout = finite_number(opts.timeout, 1.0, 0.01, 30.0),
    attempts = bounded_integer(opts.attempts, 2, 1, 16),
    ndots = bounded_integer(opts.ndots, 1, 0, 15),
  }
  for raw_line in string.gmatch((text or '') .. '\n', '([^\n]*)\n') do
    local line = strip_comment(raw_line)
    local words = {}
    for word in string.gmatch(line, '%S+') do
      words[#words + 1] = word
    end
    local directive = words[1]
    if directive == 'nameserver' and words[2] and #parsed.nameservers < 3 then
      local ok, address = pcall(numeric_address, words[2], opts.port or 53)
      if ok then
        parsed.nameservers[#parsed.nameservers + 1] = address
      end
    elseif directive == 'search' then
      parsed.search = {}
      for i = 2, #words do
        parsed.search[#parsed.search + 1] = string.lower(words[i]:gsub('%.$', ''))
      end
    elseif directive == 'domain' and words[2] and #parsed.search == 0 then
      parsed.search[1] = string.lower(words[2]:gsub('%.$', ''))
    elseif directive == 'options' then
      parse_options(words, parsed)
    end
  end
  return parsed
end

local function read_file(path, opts)
  return File.read_all(path, {
    max = tonumber(opts.maximum_config_size) or 64 * 1024,
    name = (opts.name or 'dns-config') .. ':read-resolv-conf',
  })
end

function Config.load(opts)
  opts = opts or {}
  local explicit = opts.nameservers or (opts.nameserver and { opts.nameserver })
  local config = {
    nameservers = {},
    search = copy_list(opts.search),
    timeout = finite_number(opts.timeout, 1.0, 0.01, 30.0),
    attempts = bounded_integer(opts.attempts, 2, 1, 16),
    ndots = bounded_integer(opts.ndots, 1, 0, 15),
    source = 'explicit',
  }

  if explicit then
    for i = 1, #explicit do
      config.nameservers[#config.nameservers + 1] = numeric_address(explicit[i], opts.port or 53)
    end
  else
    local content = opts.resolv_conf
    local source = 'provided resolv.conf'
    if content == nil then
      local path = opts.resolv_conf_path or '/etc/resolv.conf'
      content = read_file(path, opts)
      source = path
    end
    if content then
      local parsed = Config.parse_resolv_conf(content, opts)
      config.nameservers = parsed.nameservers
      if opts.search == nil then
        config.search = parsed.search
      end
      if opts.timeout == nil then
        config.timeout = parsed.timeout
      end
      if opts.attempts == nil then
        config.attempts = parsed.attempts
      end
      if opts.ndots == nil then
        config.ndots = parsed.ndots
      end
      config.source = source
    end
  end

  config.timeout = finite_number(config.timeout, 1.0, 0.01, 30.0)
  config.attempts = bounded_integer(config.attempts, 2, 1, 16)
  config.ndots = bounded_integer(config.ndots, 1, 0, 15)
  if #config.nameservers == 0 then
    return nil, 'no DNS name servers are configured'
  end
  return config
end

function Config.numeric_address(value, default_port)
  return numeric_address(value, default_port or 53)
end

return Config
