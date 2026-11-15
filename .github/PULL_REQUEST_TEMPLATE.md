## What this changes

One version, one theme. (See CONTRIBUTING.md for the impl → tests → docs
batches.)

## Resident suite

- New / updated suite:
- Layers covered: behavioural matrix / C oracle / every writer / coverage
  census / mutations / byte baseline
- Byte baseline drift: none / re-recorded rows (with reason)

## Gate

- [ ] `sh tests/ci.sh` passes in full, unskipped
- [ ] `aster doctor` reports 13 ok, 0 warnings

## Notes for reviewers

Anything the diff does not show: the control case, the mutation that
catches a revert, or a deliberate baseline change.
