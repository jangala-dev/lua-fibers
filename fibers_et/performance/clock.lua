-- Best available dependency-free benchmark clock.

local M = {}

if os and type(os.gettimeofday) == 'function' then
  M.now = os.gettimeofday
  M.name = 'os.gettimeofday'
elseif os and type(os.socketgettime) == 'function' then
  M.now = os.socketgettime
  M.name = 'os.socketgettime'
else
  local ok, socket = pcall(require, 'socket')
  if ok and socket and type(socket.gettime) == 'function' then
    M.now = socket.gettime
    M.name = 'socket.gettime'
  elseif os and type(os.clock) == 'function' then
    M.now = os.clock
    M.name = 'os.clock'
  else
    M.now = function() return 0 end
    M.name = 'unavailable'
  end
end

return M
