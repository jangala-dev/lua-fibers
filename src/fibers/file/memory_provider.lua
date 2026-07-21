-- Deterministic in-memory file provider for ManualHost and semantic tests.

local HostError = require('fibers.host.error')

local Provider = {}
Provider.__index = Provider
local Backend = {}
Backend.__index = Backend

local function new_inode(bytes, permissions)
  return { bytes = bytes or '', permissions = permissions or 420 }
end

function Provider.new(opts)
  opts = opts or {}
  local paths = {}
  for path, bytes in pairs(opts.files or {}) do
    paths[path] = new_inode(tostring(bytes))
  end
  local directories = {}
  for path, value in pairs(opts.directories or {}) do
    if value then
      directories[path] = true
    end
  end
  return setmetatable({ name = 'memory', paths = paths, directories = directories }, Provider)
end

function Provider:is_supported()
  return true
end

function Provider:open(path, mode, opts)
  opts = opts or {}
  local first = mode:sub(1, 1)
  local inode = self.paths[path]
  if opts.exclusive and inode then
    return nil, HostError.system('file', 'open', 'file exists', 'EEXIST', nil, { path = path })
  end
  if first == 'r' and not inode then
    return nil, HostError.system('file', 'open', 'file not found', 'ENOENT', nil, { path = path })
  end
  if not inode then
    inode = new_inode('', opts.permissions)
    self.paths[path] = inode
  elseif first == 'w' then
    inode.bytes = ''
  end
  local append = first == 'a'
  return setmetatable({
    provider = self,
    inode = inode,
    path = path,
    position = append and #inode.bytes or 0,
    append = append,
    closed = false,
  }, Backend)
end

local function data(self)
  return self.inode.bytes
end

function Backend:read(count)
  if self.closed then
    return nil, HostError.closed('file', 'read', { path = self.path })
  end
  local bytes = data(self)
  if self.position >= #bytes then
    return ''
  end
  local out = bytes:sub(self.position + 1, self.position + count)
  self.position = self.position + #out
  return out
end

function Backend:read_line(keep)
  if self.closed then
    return nil, HostError.closed('file', 'read_line', { path = self.path })
  end
  local bytes = data(self)
  if self.position >= #bytes then
    return nil
  end
  local nl = bytes:find('\n', self.position + 1, true)
  local last = nl and (nl - 1) or #bytes
  local out = bytes:sub(self.position + 1, last)
  self.position = nl and nl or #bytes
  if nl and keep then
    out = out .. '\n'
  end
  return out
end

function Backend:write(bytes)
  if self.closed then
    return nil, HostError.closed('file', 'write', { path = self.path })
  end
  if self.append then
    self.position = #self.inode.bytes
  end
  local current = data(self)
  local before = current:sub(1, self.position)
  local after = current:sub(self.position + #bytes + 1)
  self.inode.bytes = before .. bytes .. after
  self.position = self.position + #bytes
  return #bytes
end

function Backend:seek(whence, offset)
  if self.closed then
    return nil, HostError.closed('file', 'seek', { path = self.path })
  end
  local base = whence == 'set' and 0 or (whence == 'end' and #data(self) or self.position)
  local pos = base + offset
  if pos < 0 then
    return nil, HostError.invalid_argument('file', 'seek', { path = self.path })
  end
  self.position = pos
  return pos
end

function Backend:flush()
  return true
end
function Backend:sync()
  return true
end
function Backend:close()
  self.closed = true
  return true
end

function Provider:rename(from, to)
  local inode = self.paths[from]
  if not inode then
    return nil, HostError.system('file', 'rename', 'file not found', 'ENOENT', nil, { path = from })
  end
  self.paths[to], self.paths[from] = inode, nil
  return true
end

function Provider:unlink(path)
  if not self.paths[path] then
    return nil, HostError.system('file', 'unlink', 'file not found', 'ENOENT', nil, { path = path })
  end
  self.paths[path] = nil
  return true
end

function Provider:mkdir(path, opts)
  if self.directories[path] then
    return nil, HostError.system('file', 'mkdir', 'directory exists', 'EEXIST', nil, { path = path })
  end
  self.directories[path] = { permissions = (opts and opts.permissions) or 493 }
  return true
end

function Provider:mkdir_p(path, opts)
  local absolute = path:sub(1, 1) == '/'
  local current = absolute and '/' or ''
  for part in path:gmatch('[^/]+') do
    current = (current == '' or current == '/') and (current .. part) or (current .. '/' .. part)
    if not self.directories[current] then
      self.directories[current] = { permissions = (opts and opts.permissions) or 493 }
    end
  end
  return true
end

Provider.Backend = Backend
return Provider
