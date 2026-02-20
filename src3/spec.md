Below is a concrete “blessed fusion” that keeps the transactional clarity of op2 (preview/commit/abort, keys, cached payloads) but adopts your single per-fibre waker as the only waiting mechanism. It avoids pulse unions, keeps allocation low via reusable out-buffers, and keeps the surface area compact.

The essential rule is:

* **Every op is polled with a `ctx` that contains a single `ctx.waker` Pulse.**
* **If an op is not ready, it must arrange for `ctx.waker` to be signalled when it might become ready**, and return “pending” without touching the caller’s out buffer.
* `perform()` always yields on the single `ctx.waker`.

This is direct, and it keeps `choice` very close to your faster draft: probe arms, otherwise yield once.

---

## `fibers/sched.lua`

### Purpose

A minimal cooperative run queue. It never blocks the process and has no notion of time, timers, or IO.

### Core types and fields

* `Task`: `run(self, sched)`
* `Scheduler`:

  * `q, head, tail`: array queue (ring-ish reset when drained)
  * idempotence via `task._queued`

### API and behaviour

* `schedule(task)`

  * idempotent: honours `task._queued` flag (as in your draft)
  * O(1) push; clears flag when popped
* `step() -> boolean`

  * pops one task and runs it
  * returns `false` if no runnable tasks
* `run_ready(max_steps?)`

  * drains queue; allows fairness limits if desired
* `wait(timeout)`

  * if `event_waiter` exists: delegate (`event_waiter:wait(timeout)`)
  * else: blocking sleep (or `time._block(timeout)`)
* `main()`

  * loop: run ready; if none, wait (and if you have timers, compute next timeout)
* `shutdown()`

  * optional: ask sources/timers to cancel, then drain a bounded number of steps

**Compactness note:** you can keep the scheduler as small as your current one and add timers/IO later behind `event_waiter` without touching the runtime/op layers.

---

## `fibers/pulse.lua`

### Purpose

A per-fibre waker with a single waiter and a pending latch.

### Invariants

* A Pulse is awaited by at most one fibre at a time.
* If `signal()` happens before the fibre subscribes, the pulse latches `pending=true` and the *next* subscribe schedules the fibre immediately.

### Fields

* `sched`: Scheduler (needed to enqueue the fibre task)
* `waiter`: fibre task or `nil`
* `pending`: boolean

### API

* `Pulse.new(sched)`
* `signal()`

  * if `waiter` exists: clears waiter and enqueues it
  * else: `pending = true`
* `subscribe(fibre)`

  * if `pending`: clear pending and enqueue fibre
  * else: set `waiter = fibre`
  * defensive: fibre keeps `fibre._waiting_pulse` for sanity checks

This is essentially what you already have; it remains a good fit.

---

## `fibers/runtime.lua`

### Purpose

Fibres as tasks; strict yielding (only a Pulse); fibre-local context including the single waker and scratch buffers.

### Fibre task

* `Fiber.new(fn, name)`
* `Fiber:run(sched)`

  * resume coroutine (no arguments needed for the op layer)
  * if dead: drop from `_live`
  * if yielded value is not a `Pulse`: error (fast fail)
  * yielded `Pulse:subscribe(self)`

### Runtime state

* `runtime.sched`
* `runtime._current`
* `runtime._live` (weak keys optional)
* `ctx_by_fibre` weak-key table mapping fibre to:

  * `waker: Pulse`
  * `in_perform: boolean`
  * `select_top: table|nil` (current selection record for `choice`)
  * scratch buffers: small reusable `out` tables

### API

* `init(sched)`
* `spawn(fn, name)`
* `await()`

  * yields *the current fibre’s* `ctx.waker` (no argument; always the same pulse)
* `ctx()`

  * returns the fibre-local context; creates on first use
* `main()`

  * runs scheduler until no runnable tasks
  * if live fibres remain: deadlock

**Performance point:** `await()` taking no arguments is deliberate; it makes “single waker” the default and reduces accidental multi-wait designs creeping back in.

---

## `fibers/op.lua`

### Purpose

Transactional ops with reusable out-buffers, key-based caching, and a single waiting mechanism (the per-fibre waker).

### Op protocol (compact and fast)

Each op-like object implements:

* `preview(self, ctx, out) -> key|nil`

  * `key ~= nil` means **ready**

    * the op may write results into `out` (packed as `{ n=..., ... }`)
    * the key is opaque and identifies the ready reservation/signature
  * `key == nil` means **pending**

    * the op **must not** write to `out`
    * the op must ensure `ctx.waker` will be signalled when readiness might change
* `commit(self, ctx) -> nil`

  * must not block
  * finalises the reservation established by the most recent ready `preview`
* `abort(self, ctx) -> nil`

  * idempotent
  * cancels pending registrations and rolls back uncommitted reservations

This is op2’s transactional discipline, but it removes pulse unions entirely.

### `perform(op)`

* obtains `ctx`
* loop:

  * call `key = op:preview(ctx, ctx.out0)` (a reusable out buffer)
  * if ready: `op:commit(ctx)` then return unpacked results from `ctx.out0`
  * else: `runtime.await()` (yields the single waker)

**Critical contract:** primitives must signal the registered waker on *any* transition that could make a pending op become ready, *and* on invalidation of a previously-ready reservation that a sticky combinator might be holding.

### Combinators to ship

#### `wrap(op, f)`

* caches the inner key and cached transformed payload in a private prep buffer
* `preview`: if inner ready and key changed, recompute `f(...)` into prep buffer
* `commit`: commit inner; return cached prep results

Use your out-buffer helpers here; it is where they pay off most.

#### `choice(op1, op2, ...)`

* fields:

  * `ops, n, rr`
  * cached winner: `winner_i, winner_ckey`
  * `sel = { winner = nil }` for rendezvous primitives
* `preview(ctx, out)`:

  * set `ctx.select_top = self.sel` for the duration of probing
  * validate cached winner by re-previewing it; if still ready with same child key, return ready
  * otherwise probe arms in rr order:

    * `ckey = op_i:preview(ctx, out)`
    * first ready arm wins; cache `(i, ckey)` and return a choice key (monotone counter) if you want stable outer keys
  * if none ready: return `nil` (pending)

    * arms are responsible for having armed `ctx.waker` during their pending previews
* `commit(ctx)`:

  * commit winner
  * abort losers
* `abort(ctx)`:

  * abort all arms

This is close to your fast draft: no wait-set construction, no unions, no dedupe.

#### `all_offerless(...)` and `and_then_offerless(k)`

* **Offerless** means: do not hold reservations across a wait; abort before awaiting.
* `all_offerless:preview`:

  * preview each arm into per-arm buffers
  * if any pending: abort all arms that were previewed and return pending
  * else ready
* `and_then_offerless:preview`:

  * preview lhs; if pending return pending
  * if lhs ready: derive rhs; preview rhs
  * if rhs pending: abort rhs and lhs; return pending
  * else ready
* `commit`: commit in sequence (lhs then rhs / all arms)
* `abort`: abort whatever is armed/derived

These match op2’s “do not hoard”.

#### `all_sticky(...)` and `and_then_sticky(k)`

* **Sticky** means: once a sub-op becomes ready, keep its reservation while waiting for the rest.
* `and_then_sticky:preview`:

  * preview lhs; if pending return pending
  * if lhs ready and key changed, (re)derive rhs
  * preview rhs; if pending return pending **without aborting lhs**
  * if lhs becomes invalidated while waiting, `lhs:preview` must eventually return pending and signal waker
* `all_sticky:preview`:

  * maintain per-arm cached keys and buffers for arms that are already ready
  * for arms not ready, keep previewing them; if any pending, return pending **without aborting ready arms**
  * relies on primitives signalling waker if any held reservation becomes invalid

These are the variants that benefit from your channel’s targeted invalidation signalling.

### Primitive constructor

`new_primitive(state, preview_fn, commit_fn, abort_fn)`

In debug builds, it is worth enforcing:

* `commit` only after a ready preview
* pending preview does not write to out
* tickets are fibre-affine (`ctx.waker` must match any previously registered waker)

---

## `fibers/channel.lua`

### Purpose

Channels as transactional primitives that:

* arm the single per-fibre waker when pending,
* use targeted signalling (signal the exact fibres involved),
* support `choice` selection correctly (so two receives in a choice do not both “win”).

### Data structures

Use intrusive doubly-linked queues (your later draft) to avoid stale waiter accumulation.

* Channel:

  * optional buffer: circular array or FIFO for buffered channels
  * `put_h/put_t` list of Put tickets
  * `get_h/get_t` list of Get tickets

Each ticket (Put/Get) stores:

* `waker`: the owning fibre’s `ctx.waker` (fibre-affine check)
* `peer`: paired ticket if rendezvous is tentatively established
* `done`: finalised
* linkage: `prev/next/inq`
* for Get:

  * `sel`: current `ctx.select_top` (selection record)
  * prepared value caching (`prepared`, `prep_val`) to make the preview result stable

### Preview/commit/abort rules

#### Put ticket `preview(ctx, out) -> key|nil`

* if done: ready with empty payload
* store/check `self.waker == ctx.waker`
* if paired:

  * if peer’s selection disallows it, detach and return pending
  * else ready (key can simply be `peer` or an incrementing counter)
* else try to find eligible Get:

  * pair them, signal peer’s waker
  * if peer is still deciding selection, may still return pending
* if cannot pair:

  * enqueue self into put list (idempotent)
  * return pending (`nil` key)
* **Never write to `out`** (send has no payload)

`commit(ctx)`:

* if paired and not done: finalise pair (unlink both, set Get.result, mark done, clear wakers, signal both wakers)
* idempotent

`abort(ctx)`:

* if paired and peer not done: detach and signal both wakers
* unlink self if queued
* clear waker/peer; idempotent

#### Get ticket `preview(ctx, out) -> key|nil`

* if done: write `result` to out and return ready
* store/check waker; set `self.sel = ctx.select_top`
* if selection already chose someone else: detach and return pending
* if prepared:

  * validate peer/value consistency; if mismatch return pending
  * if selection unresolved, claim winner (`sel.winner = self`) and signal peer
  * write prepared value to out; ready
* else if paired or can find an unmatched Put:

  * pair; if selection unresolved, claim winner and signal put
  * if out requested: set prepared value and write it; ready
  * otherwise (rare): you can still be ready but you should not change out; simplest is to require out always provided by combinators
* else:

  * enqueue into get list
  * return pending

`commit(ctx)`:

* finalise pair if present; return result via out that was written in preview
* idempotent

`abort(ctx)`:

* detach peer if needed and signal both wakers
* unlink self
* clear prepared state

### Buffered channels

A compact approach:

* on `put.preview`: if buffer has space and no waiting receiver, push into buffer and return ready
* on `get.preview`: if buffer has data, pop and return ready
* if buffer path cannot complete, fall back to the unbuffered rendezvous logic above

---

## Why this fusion?

* **Performant**: `choice` does no union building, and `perform` yields on a single Pulse. Most allocations are avoided via reusable out-buffers.
* **Direct**: pending means “I have armed your waker; yield once”. There is no second waiting abstraction.
* **Compact**: modules stay small; the sophistication lives where it should (in primitives that manage wait queues and signalling).
