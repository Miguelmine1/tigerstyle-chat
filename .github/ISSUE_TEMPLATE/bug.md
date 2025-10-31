---
name: Bug Report
about: Report a bug or invariant violation
title: '[BUG] '
labels: 'bug'
assignees: ''
---

## Bug Description

Clear description of what went wrong.

## Severity

- [ ] **CRITICAL**: Safety invariant violated or data corruption
- [ ] **HIGH**: Liveness issue or security vulnerability  
- [ ] **MEDIUM**: Functional bug with workaround
- [ ] **LOW**: Minor issue or cosmetic problem

## Steps to Reproduce

1. 
2. 
3. 

## Expected Behavior

What should happen:

## Actual Behavior

What actually happened:

## Environment

- **Zig version**: 
- **OS**: 
- **Build mode**: Debug / ReleaseSafe / ReleaseFast
- **Commit hash**: 

## Logs/Output

```
Paste relevant logs, stack traces, or error messages
```

## Invariant Violation (if applicable)

If this is an assertion failure, which invariant was violated?

- Invariant ID: 
- Location: `src/file.zig:line`
- Assertion: 

## Reproduction

- [ ] Reproducible every time
- [ ] Reproducible intermittently
- [ ] Cannot reproduce

Simulation seed (if applicable): 

## Proposed Fix

Ideas for how to fix (optional):

## Related Issues

Relates to #
Introduced in #

---

**Remember**: Invariant violations are always CRITICAL.
