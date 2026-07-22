-- Deterministic host built from the same provider contract as native families.
return require('fibers.host.native').define(require('fibers.host.provider.manual'))
