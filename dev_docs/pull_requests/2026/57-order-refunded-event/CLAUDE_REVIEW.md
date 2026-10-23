# PR #57 — Broadcast :order_refunded when an order is marked refunded

**Reviewed:** 2026-10-22
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #57 — `timujinne:order-refunded-event` → `main`, merged as `0082043`
**Author:** timujinne
**Status:** Merged. One defect in the new broadcast fixed on `main`.

## Summary

`mark_order_refunded/1` now broadcasts `:order_refunded` on the orders topic and
the per-user topic, and `Orders` / `OrderDetail` refresh on it. The event's
shape matches the other order events and the two new tests cover the broadcast
and the no-broadcast refusal.

## Findings

- **BUG - MEDIUM** (fixed) — the only production caller of `mark_order_refunded/1`
  is `maybe_mark_linked_order_refunded/1`, reached from `record_refund/3` →
  `do_record_transaction` → `apply_transaction_to_invoice` → `handle_refund_transaction`,
  i.e. **inside the refund transaction**. The broadcast therefore fired before the
  commit. `OrderDetail.refresh_order/1` (the listener this PR extends) re-reads
  the order on the event, from another connection, and saw the still-`paid` row:
  the page stayed stale until the next event. A later raise in the transaction
  (e.g. `InvoiceEvents.enqueue/2`) would also have left listeners having seen a
  refund that rolled back. `do_record_transaction` already defers every invoice
  and transaction broadcast to after the commit for exactly this reason; the
  order one was the exception. Fix: the transition moved to a private
  `refund_order/1` with no broadcast; public `mark_order_refunded/1` still
  broadcasts (standalone callers have no surrounding transaction), and the
  in-transaction path returns `{:broadcast_order_refunded, order}` through
  `handle_refund_transaction/1` and `apply_transaction_to_invoice/2` into the
  list `do_record_transaction` sends after commit.
- **IMPROVEMENT - MEDIUM** (pre-existing, recorded in the #56 review, not
  changed) — `mark_order_paid/2` has the same problem via
  `maybe_mark_linked_order_paid/1`, and is public with a callers-visible return
  shape, so it is left on record rather than reworked here.
- **NITPICK** — the PR's tests call `mark_order_refunded/1` directly, so they
  never exercised the real path (a full refund through `record_refund/3`) and
  could not have caught the above. Added a test for that path: no
  `:order_refunded` for a partial refund, exactly one for the refund that
  zeroes the invoice. The sandbox wraps everything in a transaction, so the
  test locks in the event and its single delivery, not the post-commit timing.

## What Was Done Well

- Reuses the existing event shape and both topics; list and detail LiveViews
  were updated together.
- The refusal path is tested to broadcast nothing.

## Verdict

Approve with the fix above applied.
