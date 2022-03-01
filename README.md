# lua-fibers

A (very) WIP multitasking framework for Lua ported from the Snabb Project's fibers
library, written by Andy Wingo as an implementation of Reppy et al's PML (the
simplified evolution of CML)

## Installation

This is a pure Lua module with the following dependencies:
  - luaposix (for micro/nano timing and sleeping options, for forking and other
    operations in the future)
  - [more to come]

## Usage

You can find examples in the `/examples` directory. Currently we have a number
of working golang ported examples in the `golang_examples` sub-directory,
showing just how closely extensive and well-tested golang patterns can be
mirrored using channels created from the CML primitives.

Much of the (excellent) documentation from the [Guile manual on
fibers](https://github.com/wingo/fibers/wiki/Manual) is directly relevant here,
with the following points to bear in mind:
  - Guile's implementation runs X fibers across Y cores, with one work stealing
    scheduler per core. The Lua port is single threaded, running in a single Lua
    process. In the future we may well implement true parallelism perhaps using
    a Lanes/Lindas approach

## Progress

Of the Snabb modules the following have so far been ported and tested:

- [x] timer.lua
- [x] sched.lua
- [x] fiber.lua
- [x] op.lua
- [x] sleep.lua
- [x] channel.lua
- [ ] epoll.lua
- [ ] file.lua
- [ ] cond.lua
- [ ] queue.lua

After the basic core has been ported, the aim of this library is to implement 


## Implementing Go features

We already have goroutines, channels

## Original Snabb fibers module map

```mermaid
graph TD;
    timer.lua-->sched.lua;
    sched.lua-->fiber.lua;
    fiber.lua-->op.lua;
    fiber.lua-->sleep.lua;
    op.lua-->sleep.lua;
    epoll.lua-->file.lua;
    fiber.lua-->file.lua;
    op.lua-->file.lua;
    op.lua-->cond.lua;
    op.lua-->channel.lua;
    fiber.lua-->queue.lua;
    op.lua-->queue.lua;
    channel.lua-->queue.lua;
```

| name | function |
|--|--|
timer.lua | implements a hierarchical timer wheel
sched.lua | creates a task scheduler
channel.lua | cml channels
cond.lua | 
epoll.lua | 
fiber.lua | 
file.lua | 
op.lua | 
queue.lua | 
sleep.lua | 
timer.lua | 
