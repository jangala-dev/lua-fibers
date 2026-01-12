---@module 'fibers.utils.dlist'

---@class DListNode
---@field list DList|nil
---@field prev DListNode|nil
---@field next DListNode|nil
---@field value any
local DListNode = {}
DListNode.__index = DListNode

---@class DList
---@field head DListNode|nil
---@field tail DListNode|nil
local DList = {}
DList.__index = DList

function DListNode:remove()
  local list = self.list
  if not list then
    return false
  end

  local p, n = self.prev, self.next
  if p then p.next = n else list.head = n end
  if n then n.prev = p else list.tail = p end

  self.list, self.prev, self.next = nil, nil, nil
  self.value = nil
  return true
end

function DList:push_tail(value)
  local node = setmetatable({ list = self, prev = self.tail, next = nil, value = value }, DListNode)
  if self.tail then
    self.tail.next = node
  else
    self.head = node
  end
  self.tail = node
  return node
end

---@return DList
local function new()
  return setmetatable({ head = nil, tail = nil }, DList)
end

return {
  new = new,
  DList = DList,
}
