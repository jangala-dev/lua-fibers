# Fibers finite reference evaluator

`reference/evaluator.lua` is a deliberately small semantic oracle. It evaluates
one finite, closed operation by exhaustive copy-on-branch search and returns every
coherent world.

It contains no production-kernel machinery:

- no mutable rollback journal;
- no retained or resumable search;
- no symmetry pruning or search heuristics;
- no scheduler or hidden participant recruitment;
- no host I/O, clocks or lifetime closure;
- no effect preparation or discharge.

That omission is intentional. The file is small enough to inspect linearly and
is suitable as the first oracle for generated algebra cases and language ports.
Potential participants are stated explicitly with `Op.together`.

## Example

```lua
local Ref = require('reference.evaluator')
local Op = Ref.Op

local result = Ref.evaluate(
  Op.together(
    Op.add('stock', 1),
    Op.take('stock', 1)
  ),
  { locations = { stock = Ref.add_location(0) } }
)

assert(result.tag == 'Hit')
assert(result.worlds[1].locations.stock == 0)
```

## Outcomes

```text
Hit       one or more coherent worlds were exhaustively found
Retry     the finite closed world was exhaustively refuted
Unknown   the explicit work boundary was reached
```

`Unknown` never authorises `or_else`.

## Modelled language

```text
always, never, choice, guard, map, and_then, or_else
 each, together
read, set, add, take, at_least
put, get
emit
```

Locations use either replacement or additive algebra. This is enough to test
rollback, conflicts, independent constraint, positive sibling supply and
rendezvous without importing the production implementation.

## Intended use

The next differential layer should generate small cases in this language, run
this evaluator, translate the same case into public Fibers operations, and
compare the set of possible committed worlds. Runtime recruitment, typed effect
preparation, custody and closure should have separate small reference models
rather than being folded into this file.

## Production conformance

`tests/reference/test_frontier_conformance.lua` translates the same finite
closed rendezvous expressions into this evaluator and the production runtime.
It covers implicit complete frontiers, constrained nested `each`/`together`
graphs, Hall-deficient fallback proofs and matching backtracking.

Demand-directed recruitment remains outside this evaluator because recruitment
introduces runtime participants rather than a finite closed expression. Its
behaviour is covered separately by `tests/kernel/test_demand_frontier_matching.lua`.

Run the repository oracle with:

```sh
make test-reference
```
