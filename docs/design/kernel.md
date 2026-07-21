# Kernel implementation

The option algebra in [`../advanced/option-algebra.md`](../advanced/option-algebra.md)
is the semantic contract. The production evaluator is a lazy, resumable search
machine over a hierarchical speculative ledger. The copy-on-branch evaluator in
`reference/fibers/internal/reference_machine.lua` remains an independent oracle;
it is not a production path.

## Production layout

```text
src/fibers/internal/kernel/
    machine.lua       strands, deterministic reduction and the decision stack
    ledger.lua        segments, location projection, product joins and commit
    algebra.lua       authoritative built-in location algebras
    domain.lua        lazy exchange and transition-domain cursors
    certificate.lua   Retry facts, fallback identity and retained validation
    path.lua          activation and product-provenance paths
    trail.lua         speculative rollback journal
    ir.lua            immutable primitive programmes and transition rules
```

Supporting modules in the same directory provide dependency indexing, adaptive
search policy, deterministic choice order, instrumentation and search-session
ownership. `src/fibers/runtime.lua` is the embedding boundary.

The main boundaries are:

```text
ledger       knows no fibres or search order
algebra      owns every patch-kind decision
machine      knows no host event loop
runtime      knows no facility-specific transition semantics
reference/   contains the former view-based oracle only
```

## Lazy search machine

A perform attempt owns strands, an active queue, blocked intents, a hierarchical
ledger, a rollback trail and an explicit decision stack. Deterministic work is
drained until the machine reaches a choice, fallback or blocked domain. A
decision cursor exposes one alternative at a time; no Lua call frame retains an
unexplored branch.

This preserves the kernel's principal forms of laziness:

- guards and continuations expand only when reached;
- choices, witnesses, transitions and suppliers are traversed incrementally;
- segments arise only when a strand touches transactional state;
- reads project only the requested location;
- writer indexes arise only when sibling projection requires them;
- exact memoisation keys are threshold-activated;
- bounded sessions retain their current decision and resume in place;
- committed locations change only after validation.

A trail mark surrounds each speculative alternative. The journal records the
first field write or array-length change at each mark. Failed alternatives roll
back to the mark; a successful candidate remains live through validation and
commit.

## Paths

`path.lua` provides one parent-linked implementation for two namespaces:

- semantic activation paths, used to memoise guards and distinguish provisional
  proofs;
- product-provenance paths, used to classify sequential ancestry, independent
  siblings and interacting siblings.

Normal execution uses path objects and integer identities. Human-readable labels
are constructed only for diagnostics and retained fallback identity.

## Hierarchical ledger

Each selected request receives a root segment on first transactional access.
Product lanes receive child segments; sequential continuations retain their
segment. A segment stores only:

```text
parent segment
root and product provenance
sparse location summaries
materialised values for locations written by this segment
retired marker
```

Read-only access records one proof-wide committed version and creates no
per-segment observation cell. A read begins with the committed value, applies
ancestor summaries and then considers only other segments known to write that
location.

Visibility follows the option product law:

```text
different root          full compatible contribution
interacting sibling     full compatible contribution
independent sibling     constraining contribution only
unrelated segment       hidden
```

When all lanes complete, their summaries are joined in lane order and staged in
the parent. The child segments retire and no longer participate in projection.
Candidate collection joins root summaries in stable root order and returns one
observation map and one write map to the runtime.

## Location algebras

A location holds an algebra descriptor directly. The built-in algebras are:

```text
replace
add
presence
finite_map
machine
```

`algebra.lua` is authoritative for:

- cloning a summary;
- appending a sequential change;
- joining independent, interacting or external summaries;
- applying a summary to a value;
- projecting the constraining part of a sibling summary;
- deriving directional supply metadata.

Neither the ledger nor the IR switches independently over patch kinds. A new
algebra is admitted only when its sequential and parallel laws are explicit and
shared by materially different facilities.

## Primitive IR and transition rules

The immutable option graph contains constants, primitive programmes, choice,
bind, products, fallback, consequences and annotations. Facilities initially
construct familiar primitive descriptions such as reads, patches, claims,
serial machine transitions and witnessed transitions.

`ir.lua` compiles blocked location operations to one rule protocol:

```text
serial             whether entered rules form one ordered journal
enumerable         whether the rule exposes several witness outcomes
eager              whether it may complete before entering a domain
total              whether it is unavoidable once entered
accepts_supply     whether another participant may make it ready
supplies           declared up/down/any supply directions
cursor(...)        lazy outcomes for the current projected value
```

The production machine sees only `read`, `patch`, `transition`, `exchange`,
`snapshot` and `version_wait`. Claim, machine and witness distinctions do not
appear in its execution dispatch.

IR metadata is a conservative dependency description, not a proof. Dynamic
continuations use the global slow path unless a trusted dependency declaration
covers the operation they produce.

## Lazy domains

When no strand can reduce, `domain.lua` classifies the blocked intents and opens
one cursor. The cursor traverses, in order:

1. compatible exchanges for the most constrained exchange intent;
2. witnessed transition outcomes;
3. serial or closure transition alternatives;
4. one supplier recruitment and its exclusion branch.

Exchange pairs and supplier alternatives are not materialised as complete
frontiers. Forced exchange or serial-transition reductions are applied directly
when no unentered request can supply the domain.

## Certificates

A certificate is the sole durable representation of why a world presently
retries. It carries:

```text
external interests
validation checks
semantic activation keys
retained dependency facts
search-policy identity
```

The same object supports fallback activation, sleeping, retained-session
validation, component coordination and no-good caching. Certificates are built
incrementally and copied or canonicalised only when they outlive the immediate
search branch.

## Validation and commit

A candidate records participants, observed versions, ledger summaries, effects,
negative checks and fallback interests. Before commit the runtime verifies:

- every participant is still pending;
- observed locations retain their versions;
- negative checks still hold;
- fallback interests have not become ready;
- prepared effects still admit the candidate.

Commit applies each location summary once, increments its version and then runs
its mirror callback. The runtime driver is serial; this is not a lock-free
multi-threaded commit protocol.

## Differential assurance

The reference evaluator retains its own activation, domain and view-store
implementations under `reference/fibers/internal/`. The production and reference
machines share public operations but not speculative-state machinery. The
portable matrix therefore remains a meaningful differential check rather than a
second entry point into the production kernel.
