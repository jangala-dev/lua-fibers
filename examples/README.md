# Examples

Examples are grouped by audience and stability.

## Tutorial

`tutorial/` begins with the sequential and compositional forms from the top-level README, then introduces channels, choice, tasks, Scalar state, scope policy, memory streams, Flow composition, pipes, sockets, direct performing methods, owned name resolution, datagrams, child processes and the fuller robot-dispatch example.

## Recipes

`recipes/` contains complete facilities built from supported public modules. The implementation files return modules; files ending in `_example.lua` demonstrate their use. Their tests live beside them under `recipes/tests/`.

## Embedding

`embedding/` covers external resources, the shared host reactor, readiness and host handles.

## Lifetimes

`lifetimes/` covers effects, negotiated custody and custom settlement.

## Case studies

`case_studies/` contains trusted kernel programmes such as Petri and Calendar. They are contributor case studies, not installed version 1 modules. Their tests live beside each case study.

Run all executable examples from the repository root:

```sh
make examples LUA=texlua
```
