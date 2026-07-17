# Examples

Examples are grouped by audience and stability.

## Tutorial

`tutorial/` begins with the robot-dispatch example from the top-level README, then introduces channels, choice, tasks, Scalar state, scope policy, memory streams and Flow composition.

## Recipes

`recipes/` contains complete facilities built from supported public modules. The implementation files return modules; files ending in `_example.lua` demonstrate their use.

## Embedding

`embedding/` covers external resources, the shared host reactor, readiness and host handles.

## Lifetimes

`lifetimes/` covers effects, negotiated custody and custom settlement.

## Case studies

`case_studies/` contains trusted kernel programmes such as Petri and Calendar. They are contributor case studies, not installed version 1 modules.

Run all executable examples from the repository root:

```sh
make examples LUA=texlua
```
