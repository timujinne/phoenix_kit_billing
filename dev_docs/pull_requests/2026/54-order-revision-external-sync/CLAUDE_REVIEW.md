# PR #54 — Add an order revision and put_order_sync/2 for an external system's mark

**Reviewed:** 2026-10-21
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #54 — `timujinne:external-order-sync` → `main`, merged as `ff18c36`
**Author:** timujinne
**Status:** Merged. One lock-strength fix applied on `main`.

## Summary

`Order` gets a `metadata["revision"]` counter, bumped under a row lock by
`track_revision/1`, and a `metadata["sync"]` mark written only by
`put_order_sync/2`. `sync/1` and `where_sync/2` report a mark as current only
while its revision equals the order's.

## Findings

### IMPROVEMENT - MEDIUM — the row locks used `FOR UPDATE`, conflicting with an invoice insert  (fixed)

`Order.bump_revision/1` and `write_order_sync/2` locked the order `FOR UPDATE`.
That is the one row lock that conflicts with the `FOR KEY SHARE` an invoice
insert takes on its order through `fk_invoices_order_uuid`. #56 chose
`FOR NO KEY UPDATE` for `transition_order/2` for exactly that reason, so every
`update_order/2` that bumps the revision undid it: a concurrent
`create_invoice_from_order/2` waited for the update to commit, and a host that
inserts the invoice and then updates the order in one transaction could
deadlock against it (the update holds `NO KEY UPDATE` and waits on the
inserter's `KEY SHARE`, while the inserter waits for that update).

`FOR NO KEY UPDATE` still serializes the counting — it conflicts with itself
and with the `UPDATE` that follows — so both are switched to it. Test:
`order_revision_race_test.exs` "an invoice insert does not wait for an update
that holds the order row" (fails on the old lock, passes on the new).

### Checked and fine

- The revision/mark comparison is the same in Elixir (`sync/1`) and SQL
  (`sync_revision_current?/1`); a malformed stored revision reads as "not
  current" in both, and `where_sync(:pending)` coalesces the NULL to `false`.
- `@revision_fields` matches the schema: the only fields it leaves out are
  `internal_notes`, the `base_*` figures and `metadata`, which is handled
  separately.
- `put_order_sync/2` idempotence holds: an equal mark returns the stored map
  untouched, so `synced_at` is not refreshed.
- NITPICK (left): a `"failed"` mark with no `:error` clears a previous error,
  while the other `external_*` keys are kept. The doc says `:error` is "kept only
  with `failed`", so this matches, but it is easy to misread.
