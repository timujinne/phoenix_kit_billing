# Review follow-up — 2026-10-29

Fixed the concurrent refund race, cumulative-total reconciliation and provider matching. Payment events now retain their provider attribution. The concurrency regression also ran against the original processor in an isolated VM: it failed with two EUR 10 refund rows for one EUR 10 refund. The current processor passes the same test.

Validation used the dedicated `phoenix_kit_billing_review_61_64_test` database
with the resolved Hex dependencies. The existing default database was below
the installed core's migration floor and was left intact.

- Full suite: 1,069 tests, 0 failures, integration tests enabled.
- Payment/refund/provider regressions: 69 tests, 0 failures.
- Final concurrency and provider-request checks: 7 tests, 0 failures.
- `mix precommit`: clean, including Dialyzer (only the three existing ignored warnings).
- `git diff --check`: clean.

