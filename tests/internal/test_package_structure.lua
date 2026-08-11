package.path = table.concat({
  './src/?.lua', './src/?/init.lua', './src/?/?.lua', './?.lua', './?/init.lua', './?/?.lua', package.path,
}, ';')

local saved_runtime = package.loaded['fibers.runtime']
local saved_search = package.loaded['fibers.diagnostics.search']
local saved_io_diagnostics = package.loaded['fibers.diagnostics.io']
local saved_auto = package.loaded['fibers.io.auto']
package.loaded['fibers.runtime'] = nil
package.loaded['fibers.diagnostics.search'] = nil
package.loaded['fibers.diagnostics.io'] = nil
package.loaded['fibers.io.auto'] = nil
local Runtime = require('fibers.runtime')
assert(package.loaded['fibers.diagnostics.search'] == nil, 'core Runtime must not eagerly load search diagnostics')
assert(package.loaded['fibers.diagnostics.io'] == nil, 'core Runtime must not eagerly load I/O diagnostics')
assert(package.loaded['fibers.io.auto'] == nil, 'core Runtime must not load backend discovery')
package.loaded['fibers.runtime'] = saved_runtime or Runtime
package.loaded['fibers.diagnostics.search'] = saved_search
package.loaded['fibers.diagnostics.io'] = saved_io_diagnostics
package.loaded['fibers.io.auto'] = saved_auto

local saved_io_diagnostics_after_runtime = package.loaded['fibers.diagnostics.io']
package.loaded['fibers.diagnostics.io'] = nil
local Handle = require('fibers.io.handle')
local IOErrorModule = require('fibers.io.error')
local Platform = require('fibers.io.platform')
assert(type(Handle.new) == 'function')
assert(type(IOErrorModule.protocol) == 'function')
assert(type(Platform.new) == 'function')
assert(package.loaded['fibers.diagnostics.io'] == nil, 'explicit I/O modules must not eagerly load optional diagnostics')
package.loaded['fibers.diagnostics.io'] = saved_io_diagnostics_after_runtime

local saved_stream = package.loaded['fibers.stream']
local saved_io_stream = package.loaded['fibers.io.stream']
local saved_reactor = package.loaded['fibers.io._reactor']
package.loaded['fibers.stream'] = nil
package.loaded['fibers.io.stream'] = nil
package.loaded['fibers.io._reactor'] = nil
local PortableStream = require('fibers.stream')
assert(type(PortableStream.memory_pair) == 'function')
assert(PortableStream.open_op == nil, 'portable Stream must not retain the host-backed open delegate')
assert(package.loaded['fibers.io.stream'] == nil, 'portable Stream must not load host-backed Stream support')
assert(package.loaded['fibers.io._reactor'] == nil, 'portable Stream must not load the host reactor')
package.loaded['fibers.stream'] = saved_stream or PortableStream
package.loaded['fibers.io.stream'] = saved_io_stream
package.loaded['fibers.io._reactor'] = saved_reactor

local saved_roblox = package.loaded['fibers.roblox']
package.loaded['fibers.roblox'] = nil
local Application = require('fibers.embed.application')
local Queue = require('fibers.embed.queue')
assert(type(Application.new) == 'function')
assert(type(Queue.new) == 'function')
assert(package.loaded['fibers.roblox'] == nil, 'generic embedding must not load Roblox')
package.loaded['fibers.roblox'] = saved_roblox

local IOError = require('fibers.io.error')
local sample_error = IOError.protocol('test', 'structure', 'sample')
assert(sample_error._fibers_io_error == true, 'canonical I/O errors need the v1 marker')
assert(require('fibers.diagnostics.io') == require('fibers.internal.io_audit'))

local Ownership = require('packages.ownership')
assert(Ownership.owner_name('fibers.internal.context') == 'fibers-core')
assert(Ownership.owner_name('fibers.io.internal.acquired') == 'fibers-io')
assert(Ownership.owner_name('fibers.embed.external') == 'fibers-core')
assert(Ownership.owner_name('fibers.io.handle') == 'fibers-io')
assert(Ownership.owner_name('fibers.io.nixio') == 'fibers-io-nixio')
assert(Ownership.owner_name('fibers.roblox.host') == 'fibers-roblox')

return true
