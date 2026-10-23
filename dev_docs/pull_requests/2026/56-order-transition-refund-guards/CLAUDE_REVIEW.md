# PR #56 — Check order transitions and refund bounds against the locked row

**Reviewed:** 2026-10-21
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #56 — `timujinne:fix/order-status-and-refund-guards` → `main`, merged as `afcea14`
**Author:** timujinne
**Status:** Merged. No defect in this PR; see the #54 review for the related lock fix.

## Summary

`confirm_order`, `mark_order_paid`, `mark_order_refunded` and `cancel_order` now
run through `transition_order/2`, which re-reads the status under
`FOR NO KEY UPDATE` and hands the callback the caller's struct with that status.
`record_refund` bounds a refund by the locked invoice's `paid_amount`
(`:exceeds_paid_amount`) and applies the ledger to the locked invoice.

## Verified

- Refusals are returned, not rolled back, so the nested call inside the
  invoice-paid transaction (`maybe_mark_linked_order_paid/1`) cannot abort a
  settlement.
- `:exceeds_paid_amount` has a message in `Errors` and is handled in
  `invoice_detail/actions.ex` and `webhook_processor.ex`.
- `NO KEY UPDATE` is right for the transition lock; the revision bump in #54
  undid the benefit until the lock fix recorded there.

## Findings

- **IMPROVEMENT - MEDIUM** (pre-existing, not changed here) —
  `mark_order_paid/2` broadcasts `:order_paid` itself, and
  `apply_transaction_to_invoice/2` calls it from inside the `record_payment`
  transaction. The invoice broadcasts in that function are deferred until after
  the commit; the order one is not, so a later raise in the transaction would
  leave listeners having seen a paid order. Fixing it means returning the
  broadcast from the context instead of firing it, which changes the public
  return shape; left on record.
