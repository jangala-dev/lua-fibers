# Reference solver

This directory contains the copy-on-branch solver used as a differential oracle
for tests and performance diagnostics. It deliberately retains the module name
`fibers.internal.reference_machine`, but is outside `src/` and is not part of
the installable library.

Repository commands add `reference/` to `package.path`. An installed Fibers copy
therefore contains only the production trail solver unless the reference tree is
provided separately.
