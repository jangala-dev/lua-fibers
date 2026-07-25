-- Public non-blocking DNS stub resolver.

local Resolver = require('fibers.dns.resolver')
local Codec = require('fibers.dns.codec')
local Config = require('fibers.dns.config')

local DNS = {
  Resolver = Resolver,
  Codec = Codec,
  Config = Config,
  TYPE_A = Codec.TYPE_A,
  TYPE_AAAA = Codec.TYPE_AAAA,
  TYPE_CNAME = Codec.TYPE_CNAME,
  TYPE_SOA = Codec.TYPE_SOA,
  CLASS_IN = Codec.CLASS_IN,
}

function DNS.new(opts)
  return Resolver.new(opts)
end

return DNS
