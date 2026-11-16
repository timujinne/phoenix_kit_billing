# Follow-up for PR #69

2026-11-12 — Claude review.

- **IMPROVEMENT - MEDIUM: retry queued for any paid subscription invoice — fixed.**
  `resume_paid_subscription/1` now queues the retry only when
  `SubscriptionCharge.period_paid?/1` holds for the past-due subscription. New test:
  "paying an invoice of another period queues no retry off the schedule".
- **NITPICK: past-due query before the transaction check — fixed.** The
  `in_transaction?/0` check now runs first.
- **NITPICK: a declined payment-triggered retry cannot reschedule itself — not fixed.**
  The retry scheduled earlier still stands. See the review.
- **NITPICK: CHANGELOG entry in the feature PR — left for the release commit**, which
  should say "the period's invoice".

2026-11-15 — Grok review of everything since 0.27.0, including the commits after this PR.

- **BUG - MEDIUM: a decline while the payment-triggered job is executing drops the next retry — fixed.**
  `schedule_next_retry/1` uses the worker's uniqueness without `:executing`. The retry
  queued on payment is inserted and runs at once, so the next day it schedules conflicted
  with itself. When that job was the only one, the subscription stayed past due. A job
  that is waiting, held or already finished still keeps the slot. Test: "a paid period
  that cannot move on still queues the next day while that retry is running".
- **NITPICK from the Claude review (a declined payment-triggered retry cannot reschedule itself) — fixed**,
  the same change. A second decline beside a retry that is already scheduled still queues
  nothing more.
- **The post-commit rescue stays.** A raise while queueing the immediate retry is logged
  with its stacktrace and `mark_invoice_paid/2` still returns the paid invoice. No direct
  test: the raise is after the commit, and the suite has no insert seam. The daily retry
  still moves the subscription on.

2026-11-15 — Codex review of changes since Hex 0.27.0.

- **BUG - HIGH: a card attached after the initial read bypasses charge outcome handling — fixed.**
  The no-card path now uses `retry_charge/2`. A charge the ledger refused completes
  the job without retrying; a card decline increments the attempt count. Two
  regression tests exercise the attachment between the initial read and the lock.
- **BUG - HIGH: a delayed payment-triggered job charges a later unpaid period — fixed.**
  Automatic dunning jobs carry their period and skip a different one. Their
  uniqueness includes the period, preserving scheduled retries for later periods.
  The charge predicate also checks the period under its lock.
  Tests cover both a delayed job and a period changed after the initial read.

Details and validation are in `CODEX_REVIEW.md`.
