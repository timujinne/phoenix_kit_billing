# PR #58 — Fix the payment confirmation links: /payment/ is not a route

**Reviewed:** 2026-10-22
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #58 — `timujinne:fix-payment-confirmation-link` → `main`, merged as `e245192`
**Author:** timujinne
**Status:** Merged. No defect; one consistency cleanup applied on `main`.

## Summary

The "Print Payment Confirmation" menu item and the e-mail's payment URL were
built as `.../invoices/:id/payment/:txn`, a path no route serves. Both now go
through `Paths.payment_confirmation/2`, which matches the route in
`Web.Routes`.

## Verified

- The e-mail URL is `Routes.base_url() <> Paths.payment_confirmation(...)`. That
  is right: `Paths.*` already applies prefix and locale via `Routes.path/1`, and
  `Routes.url/1` would apply it a second time (its own doc says so).
- The tests resolve the produced link against the router rather than comparing
  strings, so they fail for any link that does not reach the print LiveView.
- The stub `Templates` module is purged on exit and the test refuses to run if
  a real one is loaded.

## Findings

- **NITPICK** (fixed) — four more links in `InvoiceDetail.Actions` (checkout
  success/cancel, invoice print, receipt, credit note) still used hardcoded
  `Routes.url("/admin/billing/...")` strings, against the "paths come from
  `PhoenixKitBilling.Paths`" convention. They resolve today, but this is how the
  payment confirmation one drifted unnoticed. Moved onto `Paths` with
  `Routes.base_url() <>`; the produced URLs are unchanged.

## What Was Done Well

- Root cause fixed at the shared helper, with a regression test that cannot
  pass on a dead link.

## Verdict

Approve.
