local socket=require("socket")
local epoll=require("epoll")
local bit = require("bit")

local s=socket.tcp()
local ok,err=s:connect("127.0.0.1",6333)
if not ok then print(err) end
s:settimeout(0)
local sfd=s:getfd()

epoll.setnonblocking(sfd)

local epfd=epoll.create()
epoll.register(epfd,sfd,epoll.EPOLLOUT)

while true do
    local events=epoll.wait(epfd,-1,512)
    for fd,event in pairs(events) do
        if bit.band(event,epoll.EPOLLIN) ~= 0 then
            local buf,err=s:receive("*l")
            if not buf then
                print(err)
                epoll.unregister(epfd,sfd)
                s:close()
                os.exit(0)
            end
            print(buf)
        elseif bit.band(event,epoll.EPOLLOUT) ~= 0 then
            local ok,err=s:send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            if not ok then
                print(err)
                epoll.unregister(epfd,sfd)
                s:close()
            end
            epoll.modify(epfd,sfd,epoll.EPOLLIN)
        elseif bit.band(event,epoll.EPOLLHUP) ~= 0 then
            print("HUP")
            epoll.unregister(epfd,sfd)
            s:close()
        end
    end
end
