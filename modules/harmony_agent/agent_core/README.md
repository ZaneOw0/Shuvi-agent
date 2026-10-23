# @harmony_agent/agent-core

`agent_core` is the deterministic workflow kernel for harmony_agent. It owns semantic DAG validation,
task and step state transitions, dependency scheduling, cancellation and deadline propagation,
restart snapshots, unknown-outcome reconciliation boundaries, bounded recovery decisions, and an
operation journal. It also owns the deterministic task/step/provider budget ledger, including
atomic hydration of a complete durable ledger image for one reconstructed task and defensive
task-scoped scope/reservation snapshots for the Runtime persistence boundary.

The module deliberately contains no LLM provider, real tool transport, persistence adapter, policy
gateway, or UI dependency. Callers supply time and execution outcomes so unit tests
and replay remain deterministic.

## Safety invariant

After restart, an interrupted side-effect-free step may become ready again. An interrupted step with
any side effect becomes `UNKNOWN_OUTCOME` and cannot be dispatched until an external reconciler
reports a confirmed outcome.

Because the frozen T01 contract has no resource-lock declaration yet, the T02 scheduler uses a
conservative conflict rule: independent side-effect-free steps may run together, while a step with
any side effect is dispatched exclusively. A future contract version may safely refine this with
explicit resource claims without weakening the current boundary.

## Verification

- Host-side Hypium: 21 passed, 0 failed, 0 ignored.
- Release `assembleHar`: passed on API 26 toolchain.
- These checks do not constitute a product HAP, install, emulator, or physical-device acceptance.
