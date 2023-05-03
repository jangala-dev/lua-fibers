local socket=require("socket")
local epoll=require("epoll")
local bit = require("bit")

local s=socket.tcp()
s:setoption("reuseaddr",true)
s:bind("*",6333)
s:listen(10000)
s:settimeout(0)
local sfd=s:getfd()

epoll.setnonblocking(sfd)

epfd=epoll.create()
epoll.register(epfd,sfd,bit.bor(epoll.EPOLLIN,epoll.EPOLLET))

local map_fd_sock={}
while true do
    local events=epoll.wait(epfd,-1,512)
    for fd,event in pairs(events) do
        if fd==sfd then
            while true do
                local c,err=s:accept()
                if not c then
                    if err=="timeout" then 
                        break
                    else
                        print(err)
                        break
                    end
                end
                c:settimeout(0)
                local cfd=c:getfd()
                map_fd_sock[cfd]=c
                epoll.setnonblocking(cfd)
                epoll.register(epfd,cfd,bit.bor(epoll.EPOLLIN,epoll.EPOLLET))
            end
        elseif bit.band(event,epoll.EPOLLIN) ~= 0 then
            while true do
                local buf,err=map_fd_sock[fd]:receive("*l")
                if not buf then
                    epoll.modify(epfd,fd,bit.bor(epoll.EPOLLOUT,epoll.EPOLLET))
                    break
                end
                print(buf)
            end
        elseif bit.band(event,epoll.EPOLLOUT) ~= 0 then
            local ok,err=map_fd_sock[fd]:send("HTTP/1.0 200 OK\r\n\r\nhello\n")
            if not ok then print(err) end
            epoll.unregister(epfd,fd)
            map_fd_sock[fd]:close()
            map_fd_sock[fd]=nil
        elseif bit.band(event,epoll.EPOLLHUP) ~= 0 then
            print("HUP")
            epoll.unregister(epfd,fd)
            map_fd_sock[fd]:close()
            map_fd_sock[fd]=nil
        end
    end
end

epoll.unregister(epfd,sfd)
epoll.close(epfd)
s:close()
