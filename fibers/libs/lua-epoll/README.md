lua-epoll
=========

Epoll module for Lua

For more details, check out sample.lua.

API:
---

#### ok,err=epoll.setnonblocking(fd)
Set a file descriptor nonblocking.

#### epfd,err=epoll.create()
Returns an epoll file descriptor.

#### ok,err=epoll.register(epfd,fd,eventmask)
Register eventmask of a file descriptor onto epoll file descriptor.

#### ok,err=epoll.modify(epfd,fd,eventmask)
Modify eventmask of a file descriptor.

#### ok,err=epoll.unregister(epfd,fd)
Remove a registered file descriptor from the epoll file descriptor.

#### events,err=epoll.wait(epfd,timeout,max_events)
Wait for events. 

#### ok,err=epoll.close(epfd)
Close epoll file descriptor.

License
---

This module is licensed under the Apache license.
