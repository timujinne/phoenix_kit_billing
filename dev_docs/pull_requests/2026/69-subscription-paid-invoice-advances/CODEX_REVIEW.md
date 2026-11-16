# Review of changes since Hex release 0.27.0

**Reviewer:** Codex. **Date:** 2026-11-15.

**Scope:** `fc92a25` (`0.27.0`) through `359a9b4`, including PR #69 and the
subsequent dunning, dependency and core compatibility changes. The Hex package API
lists [0.27.0](https://hex.pm/packages/phoenix_kit_billing/0.27.0) as the latest
published release. All 11 intervening commits were included.

Two billing races needed fixes. Both are fixed, with four regression tests in
`test/phoenix_kit_billing/subscription_billing_test.exs`.

## A newly attached card bypassed charge outcome handling

**BUG - HIGH — fixed.**

The new no-card branch called `SubscriptionCharge.run/2` directly, but that
function reloads the subscription under its row lock. A card attached after the
worker's initial read could therefore be charged from that branch.

If the charge succeeded but recording it failed, the branch returned
`{:error, {:charged_not_recorded, reason}}` to Oban. Oban would retry a charge that
must instead be reconciled by an operator. If the card declined, the callback
reported `:no_payment_method` and left `renewal_attempts` unchanged. Stripe would
keep receiving the same idempotency key and could keep replaying that decline.

The branch now uses `retry_charge/2`, which handles an unrecorded charge as a
completed job. Only an actual `:no_payment_method` outcome takes the no-card
callback; other refusals use normal decline accounting.

Both card-attachment tests failed before the fix and pass afterwards. They attach
the card after the initial database read and check the actual provider request,
attempt count and queued retries.

## A delayed payment job could charge a later period

**BUG - HIGH — fixed.**

The payment enqueue path checked that the current period was paid, but its job
carried only the subscription UUID. Another retry could advance the subscription
before that job ran. If a later renewal failed, the old job would find the
subscription past due again and charge the new period outside its retry schedule.
This can happen when a subscription has fallen several periods behind.

Automatic dunning jobs now carry `period_end` and skip a different period. Their
uniqueness includes that period, so an older available job cannot suppress recovery
or the next scheduled retry of a later period.
The charge's predicate also checks the period under the subscription lock in both
transactions, covering a change after the worker's initial read.

The delayed-job test charged the later period before the fix and now skips it,
while preserving the later period's scheduled retry.
Another regression test changes the period between the initial read and the row
lock and verifies that no invoice or charge is created for the later period.

## Core compatibility and validation

The removed feature guards correspond to APIs present in core's `v3.5.0` source:
the migration prefix validator, test preflight and module-chain helpers, translated
tab labels and user-menu flags. That core also requires `beamlab_countries ~> 2.1`,
which supplies the translations API now called directly.

- Baseline full suite: **1600 tests, 0 failures**.
- Updated subscription suite: **52 tests, 0 failures**.
- `mix precommit`: **passed**, including compilation with warnings as errors,
  unused-lock checking, Hex audit, formatting, strict Credo and Dialyzer.
- Final full suite, including integration tests: **1604 tests, 0 failures**.
