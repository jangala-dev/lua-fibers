# Performance-suite invariants

Performance changes are acceptable only when the semantic suite remains green.

The principal invariants are:

1. every benchmark validates its committed result;
2. a hard capacity limit yields `Unknown`, never `Retry`;
3. a soft quantum resumes retained execution rather than replaying guard or witness work;
4. an unchanged complete frontier avoids repeated proof search;
5. a relevant version, membership or external-resource change invalidates the affected frontier;
6. an unrelated change does not invalidate independent frontiers;
7. demand-directed recruitment preserves every connected participant world;
8. a closed frontier may prove absence only from exact balance, domain or matching facts;
9. a suggested complete matching may change search order but not the set of admissible worlds;
10. instrumentation is excluded from headline timing samples.
