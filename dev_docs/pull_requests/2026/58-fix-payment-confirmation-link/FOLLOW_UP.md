# Follow-up for PR #58

2026-10-22 — Codex review, starting from `552ccdf`.

- **BUG - MEDIUM: mixed invoice/transaction documents — fixed.** Payment
  confirmations and credit notes require the transaction to belong to the
  loaded invoice. A mismatch redirects with “Transaction not found”. Comparing
  the loaded invoice UUID preserves valid uppercase UUID route parameters.
- **BUG - MEDIUM: misleading disabled-module error — fixed.** Wrong transaction
  types now report the specific payment/refund error and return to the invoice.
- **IMPROVEMENT - MEDIUM: navigation reload — fixed.** Documents load through
  `handle_params/3`; mount retains the capability guard and print layout.
  Tests patch an already-mounted page to another invoice and assert refusal.
  Error destinations use the shared `Paths` helpers.

Validation:

- The four new initial-load ownership/type tests failed against the baseline.
- Final focused event, print and logging run: 29 tests, 0 failures.
- Full suite, including the original menu/email link regressions:
  `mix test --max-cases 6 --seed 459323` — 877 tests, 0 failures, 4 existing skips.
- `mix precommit`: passed, including strict Credo, Hex audit and Dialyzer.
- `git diff --check`: clean.

The original link fix remains intact. No new translations or core API calls
were needed; all error messages already exist in the catalogues.
