# Review since 0.27.0 — paid-invoice dunning, core 3.5.0, release-gate fix

**Reviewed:** 2026-11-15
**Reviewer:** Grok
**Range:** `0.27.0` (`fc92a25`) .. working tree
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/69 (merged, then followed up on main)
**Status:** One bug fixed. The rest of the range holds.

## Summary

Since 0.27.0, main does three things. PR #69 moves a past-due subscription on when its
period invoice is paid without a card, and the follow-up commits limit that immediate
retry to the current period. The core floor is now `>= 3.5.0 and < 4.0.0`. The tip
drops two fallbacks that only existed for cores below that floor, and removes a stale
`ex_aws_ec2` lock entry that made `mix precommit` fail after the 3.6.0 upgrade.

The paid-invoice path is the right shape: dunning reuses `SubscriptionCharge.run/2`,
a paid period is checked before the attempts cap and the grace period, and the
immediate job is unique only among `:available` jobs so it can sit beside tomorrow's
retry. The post-commit queue is correctly outside the payment transaction, and a
failure there no longer reports a saved payment as an error.

## Issues Found

### BUG - MEDIUM — A decline while the payment-triggered job is running dropped the next retry — fixed

`schedule_next_retry/1` inserted with the worker's uniqueness. That default
(`:successful`) includes `:executing`, and the period is one hour measured from
`inserted_at`. The job queued when the invoice is paid is inserted and runs within
seconds, so the next day it schedules conflicts with itself and Oban drops the
insert.

The earlier review left this because the renewal's job, scheduled the day before,
is usually still there. That job is not always there. `charged_not_recorded` marks
the subscription past due and schedules nothing; an operator then marking the
invoice paid queues the only job. A refund or a missing plan between the paid check
and the lock takes the decline path, the reschedule is dropped, and nothing runs
dunning again. The subscription stays past due, and `active?/1` still counts it as
in service. The direct `perform/1` tests never inserted an executing row, so they
could not see it.

`schedule_next_retry/1` now passes `Oban.Job.unique_states(:successful)` without
`:executing`, so the list stays the worker's default. A waiting,
held or finished job still occupies the slot, so a second decline does not queue a
second retry. An insert that returns `{:error, changeset}` is logged. Pinned by
"a paid period that cannot move on still queues the next day while that retry is
running" and "a decline does not queue a second retry while one is already
scheduled".

### The post-commit rescue — kept

`resume_paid_subscription/1` rescues any raise from the lookup or from `Oban.insert/1`
and still returns `:ok`, so `mark_invoice_paid/2` and `record_payment/3` report the
committed payment. That is the right boundary: the ledger is already committed, and
the retry scheduled earlier (or the one this fix keeps) moves the subscription on.
The log now includes the stacktrace via `crash_reason`. There is no direct test. The
raise happens after the commit, and forcing `Oban.insert/1` to raise would also fail
the invoice-event insert inside the payment transaction. Not worth a production seam.

## Checked and left as they are

- **Core floor 3.5.0.** `mix.exs`, the pin test, `CoreCompat`, `AGENTS.md` and
  `README.md` agree. The test helper no longer skips i18n, user-menu, chain-check
  and expected-schema tests for cores below the floor. `PostgresPreflight.check/1`
  on the resolved core still returns `:ok | {:error, reason, message}`.
- **Fallbacks removed at the tip.** `Migrations` calls
  `PhoenixKit.Migrations.Postgres.Helpers.validate_prefix!/1` directly. The prefix
  tests compare this chain with that function, and core 3.5.0 ships it.
  `BeamLabCountries.Translations.get_name/2` is on `beamlab_countries` 2.1.0, which
  core 3.5.0 depends on; an unknown code or locale returns `nil`, and
  `country_display_name/1` still falls through to `CountryData`.
- **`ex_aws_ec2` removed from `mix.lock`.** Nothing in the lock still requires it.
  Core 3.6.0 dropped the dependency; leaving the entry failed
  `deps.unlock --check-unused`.
- **No-card dunning creates a period invoice when the period has none**, including
  after a void. That matches the card path, is called out under Unreleased, and is
  tested. A missing card returns `:no_payment_method` before `notify_refusal/2`, so
  the subscriber is not told the payment failed.
- **A payment inside the caller's transaction queues nothing.** The charge path
  records its payment inside `SubscriptionCharge`'s transaction and moves the period
  itself. A host that wraps `mark_invoice_paid/2` relies on the retry already
  scheduled. Documented, and tested.

## Verdict

The release delta is sound once the executing-job conflict is closed. Ready for the
release commit; the Unreleased notes already describe this behaviour.
