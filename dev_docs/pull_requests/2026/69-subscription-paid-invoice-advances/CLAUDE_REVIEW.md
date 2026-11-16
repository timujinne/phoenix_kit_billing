# PR #69 — Move a past-due subscription on when its period invoice is paid without a card

**Reviewed:** 2026-11-12
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/69
**Author:** timujinne
**Head SHA:** `075f895`
**Status:** Merged; one improvement and one nitpick fixed

## Summary

Fixes a real failure. Before this PR, a subscriber paying by bank transfer had an
invoice that was marked paid, but the subscription stayed past due, and dunning
cancelled it once the grace period ran out. The fix has three parts:

- Dunning without a card now takes `SubscriptionCharge.run/2`. That path finds the paid
  invoice and moves the period on.
- A paid period is checked before the attempts cap and the grace period.
- Paying the invoice in full outside a charge queues a retry right away.

The retry is unique only among `:available` jobs. Without that, the worker's own
uniqueness, which covers every state for an hour, would drop the job next to
tomorrow's scheduled retry. Oban 2.24 accepts the custom list without a warning
because it contains an insert state.

Checked against the code:

- `charge/4`'s `payment_method: nil` clause returns `:no_payment_method` before
  `notify_refusal/2`. So a subscriber without a card does not trigger a daily
  "payment failed" notification.
- A charge's own `record_payment/3` runs inside `settle/3`'s transaction, so
  `in_transaction?/0` keeps it from queuing a retry, as the PR says.
- Webhook payments go through `record_payment/3` with no outer transaction, so they do
  queue the retry, as the CHANGELOG says.
- `period_paid?/1` reads `current_period_end`, which `Subscription` requires. Card
  dunning already called `find_period_invoice/1` before this PR.

## Issues Found

### IMPROVEMENT - MEDIUM — A retry was queued for any paid invoice of the subscription, not the current period's — fixed

`resume_paid_subscription/1` checked only that the subscription was past due. If an
invoice of another period was paid in full (an old invoice, or one made by hand with
`subscription_uuid`), it still queued a dunning run. That run found the current period
unpaid and, for a card subscription, charged the card outside the daily schedule. The
charge also counted an attempt, which could reach the cap a day early.

This is rare today, since a period invoice normally stays current until it is paid,
but the PR's own comment says the retry is for "a subscription's period invoice".
The check now loads the past-due subscription and asks
`SubscriptionCharge.period_paid?/1`. That is the same question the job asks first, so
a retry is queued only when the job would move the period on. Pinned by "paying an
invoice of another period queues no retry off the schedule", which fails without the
fix.

### NITPICK — The past-due query ran before the transaction check — fixed

`past_due? and not in_transaction?()` ran the query first. So every card renewal and
every dunning charge, which record their payment inside a transaction, made a query
whose answer was then ignored. The transaction check now comes first and short-circuits.

### NITPICK — A declined retry queued on payment cannot reschedule itself — not fixed

Suppose the invoice is refunded between the payment and the queued job's run. The job
then takes the declined path, and `schedule_next_retry/1` inserts with the worker's
default uniqueness (one hour, including `executing`). That conflicts with the queued job
itself, which is still executing and was inserted seconds earlier, so the insert is
silently dropped. No harm follows: the retry scheduled before the payment (by the
renewal or the last dunning run) is still there, which is exactly why the PR made the
payment-triggered job unique only among `:available` jobs. Left as is. Changing the
worker's uniqueness affects every insert path, and nothing is lost here.

### NITPICK — CHANGELOG entry landed in the feature PR

AGENTS.md puts CHANGELOG entries in the release commit. The `## Unreleased` section does
no harm, and the release commit should take it over. When it does, the sentence "Paying
the invoice in full outside a charge … queues a retry" should say "the period's
invoice", to match the fix above. Not changed here: the CHANGELOG belongs to the
release.

## What Was Done Well

- The re-review commits cover the hard cases: a paid period at the last attempt, a
  period refunded between the check and the lock (no attempt counted), a part payment,
  a payment inside a transaction, and a void followed by a retry.
- The no-card path reuses `SubscriptionCharge.run/2` instead of a second "is it paid"
  branch, so the locks and the move to the next period are the ones card renewals
  already use.

## Verdict

Sound, and it fixes a real cancellation of paying subscribers. The retry trigger is now
limited to the period that was paid.
