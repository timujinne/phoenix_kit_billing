# PR #58 — Fix the payment confirmation links

Reviewed: 2026-10-22 by Codex. Author: timujinne.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/58
Merge: `e245192fcc15a294c9ac4ce679bdffe7bd8406a2`.
Review baseline: `552ccdf`, including the earlier URL helper cleanup.

The link changes are correct: the menu and email both use
`Paths.payment_confirmation/2`, matching the generated routes. Followed the
links into the destination LiveViews and found the following pre-existing
problems in payment confirmations and their credit-note counterpart.

## Findings

### BUG - MEDIUM — A printable document accepts another invoice's transaction

Both print pages independently fetched the invoice UUID and transaction UUID
from the URL without checking their relationship. Combining invoice A's UUID
with invoice B's payment or refund generated a document using A's customer and
invoice details alongside B's transaction. This compromises document integrity;
the existing `manage_invoices` mount gate does not establish the relationship.

Fixed both pages to require the fetched transaction's `invoice_uuid` to match
the requested invoice. A mismatch redirects to that invoice with “Transaction
not found”. Tests use a second customer's invoice and cover payments and refunds.

### BUG - MEDIUM — Wrong transaction types report that billing is disabled

The `with` expression matched both `Billing.enabled?/0` and the transaction-type
predicate against `true`. Either returning `false` took the disabled-module
branch, making the later `%Transaction{}` error branch unreachable.

Separated module availability, invoice lookup, transaction ownership and
transaction-type validation. A refund opened as a payment confirmation now says
“Transaction is not a payment”; the converse says “Transaction is not a refund”.
Added tests for both errors, including their invoice-detail redirect.

### IMPROVEMENT - MEDIUM — Reload and validate document data on navigation

Both pages loaded their records only in `mount/3` and ignored every subsequent
`handle_params/3` call. Moved document loading to `handle_params/3`, keeping the
capability check and print layout in mount. The loader now handles each route's
current invoice and transaction IDs; error links use `Paths`. Added navigation
tests that start with a valid uppercase invoice UUID, then patch to another
invoice while keeping the transaction: both pages reject the mismatch. The
comparison uses the loaded invoice UUID, preserving valid uppercase input.

## Validation

All four new ownership/type regression tests failed against the baseline and
pass with the fixes. Existing valid print rendering and the original menu/email
route-resolution tests remain covered. Final focused invoice-event, print and
logging run: 29 tests, 0 failures. Full suite and gate results are in
`FOLLOW_UP.md`.
