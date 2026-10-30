# Review follow-up — 2026-10-29

Fixed non-Stripe invoice handling and remaining-balance checkout, added checkout request context to session reuse, and restored the legacy namespace delegate. The new provider request tests all failed before their fixes. Currency, return URL, email and compatibility regressions also failed on the review baseline.

Validation used the dedicated `phoenix_kit_billing_review_61_64_test` database
with the resolved Hex dependencies. The existing default database was below
the installed core's migration floor and was left intact.

- Full suite: 1,069 tests, 0 failures, integration tests enabled.
- Payment/refund/provider regressions: 69 tests, 0 failures.
- Final concurrency and provider-request checks: 7 tests, 0 failures.
- `mix precommit`: clean, including Dialyzer (only the three existing ignored warnings).
- `git diff --check`: clean.

