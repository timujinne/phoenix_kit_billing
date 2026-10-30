# PR #62 — Apply Stripe Checkout refunds from charge.refunded

Reviewed: 2026-10-29 by Codex. Author: timujinne.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/62
Merge: `2a115e317d6f5a82d2ed495b37a8b526df7eb400`.
Review baseline: `04353c5`.

## Findings

### BUG - HIGH — Concurrent cumulative refunds can record the same money twice

The processor reads the recorded refund total before `record_refund/3` takes
the invoice lock. Two deliveries of a EUR 10 partial refund can both calculate
EUR 10 as missing. Both inserts fit a EUR 30 invoice, so its balance becomes
EUR 10 even though Stripe refunded only EUR 10.

Fixed by calculating the missing amount and checking refund IDs inside the
same transaction and invoice lock that inserts the ledger row. The shared
ledger path still emits PubSub after its commit and enqueues durable invoice
events inside the transaction. A regression uses separate real connections,
pauses the first ledger read, and verifies that the second delivery waits and
then records nothing.

### BUG - HIGH — A recorded latest refund can hide missing earlier refunds

When a Charge includes its refund list, the processor checks the latest refund
ID before reconciling the cumulative total. If a host already recorded that
latest EUR 10 refund but an earlier EUR 10 refund is missing, a webhook reporting
EUR 20 is acknowledged without repairing the ledger.

Cumulative events now reconcile their total regardless of the latest ID.
Per-refund events retain their ID check, under the invoice lock. The regression
records the latest refund first, then verifies that the cumulative event adds
the missing EUR 10. An already-reconciled cumulative replay now returns
`:already_refunded` even when it carries a known latest refund ID.

### BUG - MEDIUM — Payment matching crosses provider boundaries

The broadened payment lookup searches provider IDs and JSON fields without
checking the payment method. A Stripe event can therefore select a host-recorded
payment belonging to another provider if its reference matches.

Matching now includes the event's provider. This also exposed an existing
attribution bug: checkout and payment handlers discarded the event's provider,
so payments whose data omitted it were recorded as Stripe. Both handlers now
carry the authoritative envelope provider into the ledger. Regressions cover
a mismatched provider and payment/refund cycles for PayPal, Razorpay and EveryPay.

## Limits

Existing money records are not relabelled automatically. Non-Stripe payments
previously mislabelled as Stripe need their payment method corrected before
their refunds can match the new provider boundary. The unmatched event retains
the PR's diagnostic note; operators must reconcile it after correcting the row.

A host-recorded refund without payment references still counts toward any
payment of the same method on that invoice. For invoices with multiple payments,
hosts should include `charge_id` or `payment_intent_id` in `provider_data` so
reconciliation can attribute that refund. This review does not invent an
allocation for ambiguous historical rows.

## Evidence and validation

The protocol review checked Stripe's [Charge reference](https://docs.stripe.com/api/charges/object)
and [webhook guidance](https://docs.stripe.com/webhooks), including cumulative
refund amounts and duplicate/out-of-order delivery. Regression and gate results
are recorded in `FOLLOW_UP.md`.
