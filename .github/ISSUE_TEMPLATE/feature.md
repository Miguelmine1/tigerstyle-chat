---
name: Feature Implementation
about: Track implementation of a new feature or component
title: '[FEAT] '
labels: ''
assignees: ''
---

## Feature Description

Brief description of what needs to be implemented.

## Scope

What is included:
- 
- 

What is NOT included:
- 
- 

## Design References

- [ ] Protocol specification updated: `docs/protocol.md`
- [ ] Message formats defined: `docs/message-formats.md`
- [ ] Invariants documented: `docs/invariants.md`

## Implementation Checklist

- [ ] Core implementation in `src/`
- [ ] Unit tests added
- [ ] Simulation test scenario added
- [ ] Property/fuzz tests (if applicable)
- [ ] Invariant assertions in place
- [ ] Documentation updated
- [ ] Pre-commit checks pass

## Invariants

List which invariants this feature affects or enforces:

- **S1**: Log monotonicity (if applicable)
- **L2**: Bounded queue depth (if applicable)
- etc.

## Test Plan

Describe how this will be tested:

1. **Unit tests**: 
2. **Simulation**: 
3. **Fuzzing**: 

## Dependencies

Blocked by:
- 

Blocks:
- 

## Acceptance Criteria

- [ ] All tests pass
- [ ] Simulation coverage for failure modes
- [ ] Code review approved
- [ ] Documentation complete

## Related Issues

Relates to #
Part of milestone: 

---

**Tiger Style Reminder**: Simple, explicit, bounded, correct.
