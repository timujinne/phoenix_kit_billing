# Follow-up for PR #57

2026-10-22 — Codex review, starting from `552ccdf`.

- **BUG - MEDIUM: payment-side order events before commit — fixed.** Silent
  confirmation/payment helpers return events for the caller to publish after
  the payment transaction returns. Standalone order APIs retain their return
  values and broadcasts. The manual invoice-payment caller consumes the same
  event list.
- **IMPROVEMENT - MEDIUM: event timing coverage — fixed.** The subscriber's
  mailbox is inspected during the durable Oban insert for both payment and
  refund operations. The payment regression fails against the original code;
  both paths pass with the fixes, including single delivery after return.
- **Validation follow-up:** the first full run exposed a pre-existing
  one-second timeout in the logging ownership-error test. An isolated retry
  passed. The test now waits up to five seconds and monitors the worker's
  normal exit while keeping its error and captured-log assertions.

Validation:

- Final focused run: 29 tests, 0 failures.
- `mix test --max-cases 6 --seed 459323`: 877 tests, 0 failures, 4 existing skips.
- `mix precommit`: passed (warnings-as-errors compilation, unused-lock check,
  Hex audit, formatting, strict Credo, Dialyzer with existing configured ignores).
- `git diff --check`: clean.

The existing subscription migration skips were preserved. No version bump or
release was performed.
