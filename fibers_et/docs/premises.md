# Proof premises

A proof premise is an open obligation in the transaction solver. It is used by
base resources whose operations cannot safely deliver an ordinary Lua value
until the surrounding proof world is known.

A resource evaluation may return one of four result classes:

- `ready(proposal)`: the resource can contribute a concrete proposal now.
- `wait(interest)`: the operation is blocked on an external future interest.
- `premise(request, wait)`: the operation is an internal proof obligation that
  may be closed by a resource-specific resolver. `wait` is optional and is used
  when an unresolved premise should also advertise an external wake interest.
- `blocked()`: the resource has no current participating world.

Premises preserve the public algebra rule that `and_then` receives ordinary Lua
values. A premise resolver closes compatible open premises by providing concrete
result packs. The solver resumes the suspended continuations with those values
and continues proof search.

## Resolver contract

A resource kind may expose:

```lua
Kind.resolve_premises(resource, premises, ctx) -> { solution, ... }
Kind.absence_premises(resource, premises, ctx) -> true | false
```

A resolver must be pure proof-search code:

- it must not mutate committed resource state;
- it must not yield;
- it must not run user callbacks;
- it must enumerate deterministic, finite solution candidates;
- every result pack it returns must contain ordinary concrete Lua values;
- any resource mutation must be described as a proposal, applied later by the
  normal prepare/apply path.

The `ctx` object currently supplies:

- `ctx:compatible(a, b)`, which is false for premises that may not rely on each
  other, for example internal lanes of `Op.all`;
- `ctx.pack(...)`, the ordinary result-pack constructor;
- `ctx:resource_records(resource, premises)`, a compatibility wrapper returning
  raw records already proposed by the relevant premise tasks and product lanes;
- `ctx:resource_record_views(resource, premises)`, the provenance-aware form.

A record view has this shape:

```lua
{
  rec = record,
  relation = "own" | "outer" | "sibling",
  allow_internal = true | false,
  group = product_group_or_nil,
  lane = lane_number_or_nil,
}
```

Premise resolvers that care about `all`/`tensor` distinctions should use
`resource_record_views`. Own and outer records are always visible to the lane.
Sibling records from a `tensor` product may provide positive supply. Sibling
records from an `all` product may constrain allocation, but must not make an
otherwise unsatisfied lane satisfiable.

## Solution shape

A premise solution has this shape:

```lua
{
  ids = { premise_id_1, premise_id_2 },
  results = {
    [premise_id_1] = ctx.pack(...),
    [premise_id_2] = ctx.pack(...),
  },

  -- Optional. Carried as a once-only proof contribution for the solution
  -- as a whole.
  proposal = proposal,

  -- Optional. Legacy/per-premise proposals, merged into the named premise task.
  proposals = {
    [premise_id_1] = proposal_1,
  },
}
```

Use the shared `proposal` field when the solution represents one allocation
across several premises. The solver stores this proposal as a once-only proof
contribution frame. Each resumed premise task is continued below a frame carrying
the same contribution id; when those environments later merge, equal ids collapse
to one proposal. The frame is ordered: the contribution is after the environment
that opened the premise and before any records produced by the continuation.

This is deliberately not assigned to an arbitrary premise lane. For example,
two `Index:pop_first_op()` premises can be closed by one solution that removes
two selected entries. That removal proposal is evidence for the solution as a
whole, not a resource delta owned by either pop lane individually.

## Proof contributions

A proof contribution is the internal representation of a shared solution
proposal. It is similar in spirit to an effect set: several environments may
mention the same contribution id, but the proposal is considered once. Unlike a
flat side set, a contribution is carried in an ordered proof frame.

The rules are:

- a contribution id denotes one shared proof fact;
- environment copying preserves contribution frames;
- a resumed premise continues beneath a fresh child of the contribution frame,
  so later `and_then` work is sequentially after the resolver-created fact;
- sequential and parallel environment merges deduplicate contribution ids;
- overlay and preparation flatten frames in order, expanding each unique
  contribution proposal exactly once at its frame position;
- contributions are rolled back with the speculative environments that carry
  them.

Contributions are used for resolver-created facts such as Index selected-removal
deltas and Counter allocated-take deltas. They avoid the older bookkeeping trick
of merging a shared proposal into the first resolved premise environment, while
still preserving ordinary bind sequencing. For example, a pop followed by an
`and_then` reinsert of the same key is a sequential replacement, not a parallel
insert/pop handoff.

## Absence

If no resolver solution can close the currently open premises, the solver asks
`Kind.absence_premises` for a resource-specific absence certificate. This is the
premise equivalent of a resource leaf `absence` hook.

The hook should record the mutable facts that justify the miss. For example:

- rendezvous certifies that no compatible endpoint exists at the observed offer
  frontier;
- index selection certifies that no eligible entry exists at the observed index
  frontier;
- counter take certifies that insufficient units are available at the observed
  counter frontier.

A generic fallback certificate is still produced when no hook exists, but base
resources intended for public composition should provide a specific absence hook.

## Determinism

Premise buckets are enumerated in stable resource-id order, and premises within a
bucket are passed to resolvers in premise-id order. Resolver output order remains
semantic: a resolver should put its preferred solution first.

## Current resources

Synchronous rendezvous is implemented as a premise resource. Rendezvous `get` and
`put` open premises, and `Rendezvous.Kind.resolve_premises` closes compatible
get/put pairs.

`Scalar` is the replacement state atom. `read_op` and `write_op` are ordinary
resource records; `expect_op(value)` opens a premise. Sibling writes that make an
expectation false are constraints under both `all` and `tensor`; sibling writes
that make an expectation true are positive supply and are visible only under
`tensor`. This gives gate-like state, such as pool open/closed, the same
allocation-versus-handoff discipline as the stock atoms.

Bounded `Counter` is implemented as a premise-aware stock resource. Positive
deltas such as `give_op` are ordinary records; `adjust_op` is the explicit signed expert operation. `take_op` opens a premise so
parallel takes can be allocated from the same committed/projected stock before
continuations run. Counter uses the same allocation-versus-handoff law as
Index: `all` may allocate several takes from committed stock, but a sibling
`give_op` in `all` does not make an otherwise unavailable take possible.
`tensor` may treat that sibling give as positive supply.

Ordered `Index` is implemented as a premise resource. `pop_first_op`
and `pop_last_op` open selection premises. The index resolver builds a
projected ordered arena from the committed index plus provenance-filtered
transaction records.

The arena law follows the algebraic distinction between allocation and handoff:

- own-lane and outer records are fully visible;
- sibling records from `tensor` are fully visible and may provide entries to be
  selected;
- sibling records from `all` are visible only as constraints. Their removals and
  selected-removals are honoured, but their inserts do not provide positive
  supply to the premise lane.

This means `Op.all` can allocate two different committed entries to two pop
lanes, and a sibling remove can make a pop skip the removed entry. It cannot make
an empty pop lane succeed merely because a sibling inserted an entry.
`Op.tensor` may do that handoff.

Selections allocate concrete entries from the arena and return one shared
proposal with selected-removal deltas. A selected-removal delta is distinct from
an explicit removal. This lets an inserted entry be consumed by a tensor-internal
pop without leaving a final entry and without making ordinary explicit
remove-plus-insert ambiguous. For example,
`Op.tensor({ ix:insert_op("z", 0, "Z"), ix:pop_first_op() })` may deliver the
inserted entry to the popper and leave no `z` entry committed. Only after this
allocation do `map` and `and_then` run.

`Queue` is the first ordinary higher-level structure built from these premise
atoms. It is not a kernel resource: it combines `Index` for ordered entries and
`Counter` for optional bounded capacity. Queue puts use `Index:append_op`, so
constructing a put operation does not mutate queue state; ordering is carried as
an index append record. Consequently,
`Op.tensor({ q:put_op(v), q:get_op() })` can hand off `v`, while
`Op.all({ q:put_op(v), q:get_op():or_else(Op.always(empty)) })` commits the put
and lets the get lane take the absence fallback.


## Scalar transition premises

`Scalar.transition` and `Scalar.kind` define typed scalar state-machine
transitions. A transition may provide `validate(payload)` to reject invalid
payloads before proof search. `scalar:transition_op(transition, payload)` opens a transition
premise. The resolver supplies the projected scalar value to the transition
`step`, records the returned new value as an ordered proof contribution, and
resumes the task with the remaining returned values. Update and select
transition premises are resolved one at a time in transition order. This is
deliberately a serial state-machine law rather than a stock-allocation law: use
`Counter`, `Index`, `Keyed` or `Lease` when the primitive needs stock allocation
behaviour.

A transition callback must be pure transaction construction logic. It must not
perform external side effects; use `Effect` for work that should happen only
after commit. Raw `unsafe_update_op` and `unsafe_select_op` are low-level
transition-building mechanisms rather than the normal public idiom.


## Scalar select transitions

A typed scalar transition with `mode = 'select'` is the state-machine analogue of `Index:pop_first_op` or
`Keyed:remove_present_op`. The transition step receives the projected scalar value and payload. If
it returns `nil`, the selection is absent and may wait or take an `or_else`
fallback. Otherwise it returns the new scalar value followed by result values.

A select transition observes sibling positive supply under `tensor`, but not under `all`.
Sibling updates that make a previously possible selection impossible remain
visible as constraints. This lets state-machine facilities such as `Flow` keep
the same handoff law as `Queue`:

```lua
Op.tensor({ inlet:write_op("abc"), outlet:read_op(3) }) -- handoff
Op.all({ inlet:write_op("abc"), outlet:read_op(3):or_else(Op.always("empty")) }) -- no handoff
```
