# PR #57 — Broadcast :order_refunded when an order is marked refunded

Reviewed: 2026-10-22 by Codex. Author: timujinne.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/57
Merge: `00820433711a5f4a52fa05a20c2378e1ff9263f6`.
Review baseline: `552ccdf`, including the earlier refund broadcast fix.

## Findings

### BUG - MEDIUM — Linked order payments still broadcast inside the payment transaction

The refund fix correctly collects `:order_refunded` for publication after
`record_refund/3` commits. The sibling payment path still called public
`confirm_order/1` and `mark_order_paid/2` inside `apply_transaction_to_invoice/2`.
Those functions broadcast immediately, before durable invoice events have even
been inserted. A subscriber can reload the old order, and a later rollback can
leave an announcement for a payment that did not commit. This is pre-existing
payment-path behavior found while checking #57's transaction guarantees.

Fixed by separating the silent confirmation and payment transitions from their
public broadcast wrappers. `maybe_mark_linked_order_paid/1` returns broadcast
descriptors, just as the refund helper does. `record_payment/3` publishes them
with the invoice and transaction events after its transaction returns. The
manual `mark_invoice_paid/2` caller also consumes the descriptors; its public
return value and the standalone order APIs remain unchanged.

### IMPROVEMENT - MEDIUM — Exercise event timing before the operation returns

The previous refund tests only read their mailbox after `record_refund/3`
returned, so they could pass even when publication happened inside its
transaction. Added tests that inspect the subscriber's mailbox synchronously
when Oban inserts the durable event, while billing is still inside the
transaction. No confirmation, payment or refund announcement may already be
there; the expected events must arrive once after the operation returns.

The tests use the existing SQL sandbox. They establish ordering relative to the
in-transaction enqueue, rather than measuring visibility from an independent
connection or promising deferral past a host-supplied outer transaction.

## Verified

- Refund publication goes to both the admin and per-user order topics.
- A partial refund does not publish `:order_refunded`; completing the refund does.
- Both admin order listeners include `:order_refunded` and re-read their data.
- Standalone confirmation/payment/refund transitions still validate stored status
  under the existing row lock.

## Validation

The new payment timing test also fails against the baseline: both order
announcements are already in the mailbox at enqueue time. Final focused
invoice-event, print and logging tests: 29 tests, 0 failures.
Full test suite and project gate: results recorded in `FOLLOW_UP.md`.

An initial full run found one unrelated activity-log test timeout: the bare
worker returned the expected ownership error after its one-second deadline.
Its isolated retry passed. Increased that scheduling allowance to five seconds
and monitor the worker through normal exit, retaining the real ownership-error
and captured-log assertions.
